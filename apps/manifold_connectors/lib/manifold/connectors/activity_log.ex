defmodule Manifold.Connectors.ActivityLog do
  @moduledoc false

  @uuid_re ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @spec append(String.t(), map()) :: :ok | {:error, term()}
  def append(account_id, entry) when is_map(entry) do
    append_for_date(account_id, Date.utc_today(), entry)
  end

  @spec append_for_date(String.t(), Date.t(), map()) :: :ok | {:error, term()}
  def append_for_date(account_id, %Date{} = date, entry) when is_map(entry) do
    with {:ok, account_id} <- validate_account_id(account_id),
         dir <- account_dir(account_id),
         :ok <- File.mkdir_p(dir),
         path <- day_path(account_id, date),
         line <- Jason.encode!(entry) <> "\n",
         :ok <- File.write(path, line, [:append]) do
      :ok
    end
  end

  @spec list_dates(String.t()) :: {:ok, [Date.t()]} | {:error, :invalid_account_id}
  def list_dates(account_id) do
    with {:ok, account_id} <- validate_account_id(account_id) do
      dir = account_dir(account_id)

      dates =
        case File.ls(dir) do
          {:ok, files} ->
            files
            |> Enum.filter(&String.ends_with?(&1, ".log"))
            |> Enum.flat_map(fn name ->
              case Date.from_iso8601(String.trim_trailing(name, ".log")) do
                {:ok, date} -> [date]
                _ -> []
              end
            end)
            |> Enum.sort({:desc, Date})

          {:error, :enoent} ->
            []

          {:error, _} ->
            []
        end

      {:ok, dates}
    end
  end

  @spec read(String.t(), Date.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, :invalid_account_id}
  def read(account_id, %Date{} = date, limit \\ 200)
      when is_integer(limit) and limit > 0 do
    with {:ok, account_id} <- validate_account_id(account_id) do
      path = day_path(account_id, date)

      entries =
        case File.read(path) do
          {:ok, contents} ->
            contents
            |> String.split("\n", trim: true)
            |> Enum.reverse()
            |> Enum.reduce_while({[], 0}, fn line, {acc, count} ->
              if count >= limit do
                {:halt, {acc, count}}
              else
                case Jason.decode(line) do
                  {:ok, map} when is_map(map) -> {:cont, {[map | acc], count + 1}}
                  _ -> {:cont, {acc, count}}
                end
              end
            end)
            |> elem(0)
            |> Enum.reverse()

          {:error, :enoent} ->
            []

          {:error, _} ->
            []
        end

      {:ok, entries}
    end
  end

  @spec prune(String.t()) :: :ok | {:error, :invalid_account_id}
  def prune(account_id) do
    with {:ok, account_id} <- validate_account_id(account_id),
         {:ok, dates} <- list_dates(account_id) do
      cutoff = Date.add(Date.utc_today(), -retention_days())

      Enum.each(dates, fn date ->
        if Date.compare(date, cutoff) == :lt do
          _ = File.rm(day_path(account_id, date))
        end
      end)

      :ok
    end
  end

  @doc false
  def day_path!(account_id, date) do
    {:ok, account_id} = validate_account_id(account_id)
    day_path(account_id, date)
  end

  @spec validate_account_id(term()) :: {:ok, String.t()} | {:error, :invalid_account_id}
  def validate_account_id(account_id) when is_binary(account_id) do
    cond do
      String.contains?(account_id, ["..", "/", "\\"]) ->
        {:error, :invalid_account_id}

      Regex.match?(@uuid_re, account_id) ->
        {:ok, account_id}

      true ->
        {:error, :invalid_account_id}
    end
  end

  def validate_account_id(_), do: {:error, :invalid_account_id}

  defp day_path(account_id, %Date{} = date),
    do: Path.join(account_dir(account_id), Date.to_iso8601(date) <> ".log")

  defp account_dir(account_id), do: Path.join(root_dir(), account_id)

  defp root_dir do
    Application.get_env(:manifold_connectors, :activity_log_dir, "log/connectors")
  end

  defp retention_days do
    Application.get_env(:manifold_connectors, :activity_log_retention_days, 14)
  end
end
