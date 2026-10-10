defmodule ManifoldWeb.BuildInfo.Source do
  @moduledoc false

  @project_root Path.expand("../../../..", __DIR__)

  # This helper is used only while compiling or checking whether recompilation is needed.
  def current do
    %{
      version: Mix.Project.config()[:version],
      environment: Mix.env(),
      git_ref:
        env("MANIFOLD_GIT_REF") || git(["symbolic-ref", "--quiet", "--short", "HEAD"]) ||
          git(["describe", "--tags", "--always"]),
      git_sha: env("MANIFOLD_GIT_SHA") || git(["rev-parse", "HEAD"]),
      built_at: env("MANIFOLD_BUILD_TIME"),
      released_at: env("MANIFOLD_RELEASE_TIME")
    }
  end

  defp env(name) do
    case System.get_env(name) do
      value when value in [nil, ""] -> nil
      value -> value
    end
  end

  defp git(args) do
    case System.find_executable("git") do
      nil ->
        nil

      executable ->
        case System.cmd(executable, args, cd: @project_root, stderr_to_stdout: true) do
          {value, 0} -> String.trim(value)
          _ -> nil
        end
    end
  end
end

defmodule ManifoldWeb.BuildInfo do
  @moduledoc "Build metadata captured at compilation and available in packaged releases."

  @source ManifoldWeb.BuildInfo.Source.current()
  @metadata Map.update!(@source, :built_at, fn value ->
              value || DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
            end)

  def current, do: @metadata

  def __mix_recompile__?, do: ManifoldWeb.BuildInfo.Source.current() != @source
end
