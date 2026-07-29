defmodule Manifold.Ingest do
  @moduledoc """
  Inbound SMTP acceptance, lifecycle, and archival APIs.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Manifold.Accounts
  alias Manifold.Core.{DeliveryState, Error}
  alias Manifold.Ingest.Jobs.{ArchiveRawEmail, EvaluateInboundSecurity, ProjectInboundMail}
  alias Manifold.Ingest.Schema.{DeliveryRecipient, InboundDelivery, MessageEvent}
  alias Manifold.Mail
  alias Manifold.Mail.InboundSource
  alias Manifold.Ingest.View.DeliveryDetail
  alias Manifold.Repo
  alias Manifold.Security
  alias Manifold.Security.Input, as: SecurityInput
  alias Manifold.Storage.{RawStore, Spool}
  alias Manifold.Storage.Spool.Bundle

  @type accept_result :: {:ok, InboundDelivery.t()} | {:error, Error.t()}

  @spec accept_transport(binary(), map(), [map() | struct()], Keyword.t()) :: accept_result()
  def accept_transport(raw, attrs, frozen_routes, opts \\ []) when is_binary(raw) do
    spool_opts = Keyword.get(opts, :spool_opts, [])

    spool_attrs =
      attrs
      |> Map.put(:routes, frozen_routes)
      |> Map.put_new(:received_at, DateTime.utc_now())
      |> Map.put_new(
        :original_recipients,
        Enum.map(frozen_routes, &route_field(&1, :original_recipient))
      )

    with {:ok, bundle} <- Spool.write_bundle(raw, spool_attrs, spool_opts),
         :ok <- maybe_fault(opts, :after_spool_before_accept),
         {:ok, delivery} <- accept(bundle, frozen_routes, opts) do
      {:ok, delivery}
    end
  end

  @spec accept(Bundle.t(), [map() | struct()], Keyword.t()) :: accept_result()
  def accept(%Bundle{} = bundle, frozen_routes, opts \\ []) when is_list(frozen_routes) do
    routes = Enum.map(frozen_routes, &normalize_route/1)

    with :ok <- validate_frozen_routes(bundle, routes) do
      persist_acceptance(bundle, routes, opts)
    end
  rescue
    DBConnection.ConnectionError ->
      {:error,
       Error.new(:temporary, :database_unavailable, "database is temporarily unavailable")}
  end

  defp persist_acceptance(bundle, routes, opts) do
    now = DateTime.utc_now()
    recipient_rows = build_recipient_rows(routes, now)

    multi =
      Multi.new()
      |> Multi.insert(:delivery, InboundDelivery.acceptance_changeset(%InboundDelivery{}, bundle))
      |> Multi.run(:maybe_fail_after_delivery, fn _repo, _changes ->
        case maybe_fault(opts, :after_delivery_insert_before_commit) do
          :ok -> {:ok, :ok}
          {:error, error} -> {:error, error}
        end
      end)
      |> Multi.insert_all(:delivery_recipients, DeliveryRecipient, fn %{delivery: delivery} ->
        add_delivery_id(recipient_rows, delivery.id)
      end)
      |> Mail.add_acceptance_entries(:mailbox_entries, :delivery, routes, now)
      |> Multi.insert(:accepted_event, fn %{delivery: delivery} ->
        MessageEvent.event_changeset(
          delivery.id,
          "accepted",
          %{ingest_id: delivery.ingest_id},
          now
        )
      end)
      |> Multi.insert(:archive_job, fn %{delivery: delivery} ->
        ArchiveRawEmail.new(%{"inbound_delivery_id" => delivery.id})
      end)

    case Repo.transaction(multi) do
      {:ok, %{delivery: delivery}} ->
        :telemetry.execute(
          [:manifold, :ingest, :accept, :stop],
          %{raw_size: delivery.raw_size},
          %{
            ingest_id: delivery.ingest_id,
            delivery_id: delivery.id
          }
        )

        {:ok, delivery}

      {:error, _step, %Error{} = error, _changes} ->
        {:error, error}

      {:error, _step, reason, _changes} ->
        {:error,
         Error.new(:temporary, :acceptance_failed, "acceptance transaction failed", %{
           reason: inspect(reason)
         })}
    end
  end

  @spec list_inbound_deliveries() :: [InboundDelivery.t()]
  def list_inbound_deliveries do
    InboundDelivery
    |> order_by([d], desc: d.received_at)
    |> limit(100)
    |> Repo.all()
  end

  @spec get_inbound_delivery!(Ecto.UUID.t()) :: InboundDelivery.t()
  def get_inbound_delivery!(id), do: Repo.get!(InboundDelivery, id)

  @spec get_delivery_detail!(Ecto.UUID.t()) :: DeliveryDetail.t()
  def get_delivery_detail!(id) do
    delivery =
      InboundDelivery
      |> preload([:delivery_recipients, :message_events])
      |> Repo.get!(id)

    mailbox_ids =
      delivery.delivery_recipients
      |> Enum.map(& &1.mailbox_id)
      |> Enum.uniq()

    mailboxes =
      Enum.map(mailbox_ids, fn mailbox_id ->
        mailbox = Accounts.get_mailbox!(mailbox_id)

        %{
          id: mailbox.id,
          local_part: mailbox.local_part,
          domain_id: mailbox.domain_id,
          display_name: mailbox.display_name
        }
      end)

    %DeliveryDetail{
      delivery: delivery,
      recipients: delivery.delivery_recipients,
      mailboxes: mailboxes,
      events: delivery.message_events
    }
  end

  @spec archive_delivery(Ecto.UUID.t(), Keyword.t()) :: :ok | {:error, Error.t()}
  def archive_delivery(delivery_id, opts \\ []) do
    case Repo.get(InboundDelivery, delivery_id) do
      nil ->
        {:error, Error.new(:permanent, :not_found, "delivery not found")}

      %InboundDelivery{raw_storage_state: "archived"} = delivery ->
        with {:ok, _job} <- ensure_projection_job(delivery.id),
             {:ok, _job} <- ensure_security_job(delivery.id),
             :ok <- cleanup_archived_bundle(delivery, opts) do
          :ok
        end

      %InboundDelivery{} = delivery ->
        archive_spooled_delivery(delivery, opts)
    end
  end

  @spec mark_missing_spool(InboundDelivery.t()) :: :ok | {:error, term()}
  def mark_missing_spool(%InboundDelivery{id: delivery_id}) do
    result =
      Repo.transaction(fn ->
        delivery =
          InboundDelivery
          |> where([delivery], delivery.id == ^delivery_id)
          |> lock("FOR UPDATE")
          |> Repo.one!()

        if delivery.raw_storage_state == "spooled" do
          with :ok <-
                 DeliveryState.validate_raw_transition(
                   delivery.raw_storage_state,
                   "missing_spool"
                 ),
               :ok <-
                 DeliveryState.validate_processing_transition(
                   delivery.processing_state,
                   "failed"
                 ),
               {:ok, missing} <-
                 delivery
                 |> InboundDelivery.state_changeset(%{
                   raw_storage_state: "missing_spool",
                   processing_state: "failed",
                   last_error: "ready spool bundle is missing before archival"
                 })
                 |> Repo.update(),
               {:ok, _event} <-
                 MessageEvent.event_changeset(
                   delivery.id,
                   "missing_spool",
                   %{},
                   DateTime.utc_now()
                 )
                 |> Repo.insert() do
            missing
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        else
          delivery
        end
      end)

    case result do
      {:ok, _delivery} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec restore_spooled(Ecto.UUID.t()) :: {:ok, InboundDelivery.t()} | {:error, term()}
  def restore_spooled(delivery_id) do
    Repo.transaction(fn ->
      delivery =
        InboundDelivery
        |> where([delivery], delivery.id == ^delivery_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      case delivery.raw_storage_state do
        "spooled" ->
          delivery

        state ->
          with :ok <- DeliveryState.validate_raw_transition(state, "spooled"),
               :ok <-
                 DeliveryState.validate_processing_transition(
                   delivery.processing_state,
                   "accepted"
                 ),
               {:ok, restored} <-
                 delivery
                 |> InboundDelivery.state_changeset(%{
                   raw_storage_state: "spooled",
                   processing_state: "accepted",
                   last_error: nil
                 })
                 |> Repo.update(),
               {:ok, _event} <-
                 MessageEvent.event_changeset(
                   delivery.id,
                   "spool_restored",
                   %{},
                   DateTime.utc_now()
                 )
                 |> Repo.insert() do
            restored
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  @spec project_delivery(Ecto.UUID.t(), Keyword.t()) :: :ok | {:error, Error.t()}
  def project_delivery(delivery_id, opts \\ []) do
    requested_versions = requested_projection_versions(opts)

    with {:ok, delivery} <- begin_projection(delivery_id, requested_versions) do
      case Mail.project_inbound(inbound_source(delivery), opts) do
        {:ok, result} ->
          with :ok <- maybe_fault(opts, :after_projection_before_state_update),
               {:ok, _delivery} <- finish_projection(delivery.id, result) do
            :ok
          end

        {:error, %Error{class: :permanent} = error} ->
          case fail_projection(delivery.id, error, requested_versions) do
            {:ok, _delivery} -> {:error, error}
            {:error, %Error{} = lifecycle_error} -> {:error, lifecycle_error}
          end

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end
  end

  @spec evaluate_security(Ecto.UUID.t(), Keyword.t()) :: :ok | {:error, Error.t()}
  def evaluate_security(delivery_id, opts \\ []) do
    raw_store_opts = Keyword.get(opts, :raw_store_opts, [])

    with %InboundDelivery{} = delivery <- Repo.get(InboundDelivery, delivery_id),
         :ok <- validate_security_source(delivery, raw_store_opts),
         {:ok, _assessment} <- Security.evaluate(security_input(delivery), opts) do
      :telemetry.execute(
        [:manifold, :ingest, :security, :stop],
        %{raw_size: delivery.raw_size},
        %{delivery_id: delivery.id, ingest_id: delivery.ingest_id}
      )

      :ok
    else
      nil ->
        {:error, Error.new(:permanent, :not_found, "delivery not found")}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(:temporary, :security_evaluation_failed, "security evaluation failed", %{
           reason: inspect(reason)
         })}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error, Error.new(:temporary, :database_unavailable, "database is unavailable")}
  end

  defp archive_spooled_delivery(delivery, opts) do
    raw_path = Path.join(delivery.spool_bundle_path, "raw.eml")

    with :ok <- verify_spool_file(raw_path, opts),
         {:ok, domain_id} <- first_domain_id(delivery.id),
         key = RawStore.build_key(domain_id, delivery.received_at, delivery.id),
         {:ok, stat} <- ensure_raw_stored(delivery, key, raw_path, opts),
         :ok <- verify_raw_stat(delivery, stat),
         :ok <- maybe_fault(opts, :after_raw_copy_before_update),
         {:ok, archived_delivery} <- commit_archived_state(delivery.id, key),
         :ok <- maybe_fault(opts, :after_archived_state_before_cleanup),
         :ok <- cleanup_archived_bundle(archived_delivery, opts) do
      :telemetry.execute([:manifold, :ingest, :archive, :stop], %{raw_size: delivery.raw_size}, %{
        delivery_id: delivery.id,
        ingest_id: delivery.ingest_id
      })

      :ok
    else
      {:error, :missing_spool} ->
        :ok = mark_missing_spool(delivery)

        {:error,
         Error.new(:permanent, :missing_spool, "ready spool bundle is missing before archival")}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(:temporary, :object_store_failed, "raw object archival failed", %{
           reason: inspect(reason)
         })}
    end
  end

  defp ensure_raw_stored(delivery, key, raw_path, opts) do
    raw_store_opts = Keyword.get(opts, :raw_store_opts, [])

    case RawStore.stat(key, raw_store_opts) do
      {:ok, stat} ->
        case verify_raw_stat(delivery, stat) do
          :ok -> {:ok, stat}
          {:error, %Error{}} -> RawStore.put_from_path(key, raw_path, raw_store_opts)
        end

      {:error, reason} when reason in [:enoent, :not_found] ->
        RawStore.put_from_path(key, raw_path, raw_store_opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_raw_stat(delivery, %{size: size, sha256: sha256}) do
    cond do
      size != delivery.raw_size ->
        {:error, Error.new(:temporary, :object_store_failed, "archived raw size mismatch")}

      sha256 && sha256 != delivery.raw_sha256 ->
        {:error, Error.new(:temporary, :object_store_failed, "archived raw SHA-256 mismatch")}

      true ->
        :ok
    end
  end

  defp commit_archived_state(delivery_id, key) do
    Repo.transaction(fn ->
      delivery =
        InboundDelivery
        |> where([delivery], delivery.id == ^delivery_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      case delivery.raw_storage_state do
        "archived" ->
          if delivery.raw_object_key == key do
            delivery
          else
            Repo.rollback(
              Error.new(
                :permanent,
                :invalid_state_transition,
                "delivery is archived under a different raw object key"
              )
            )
          end

        state ->
          with :ok <- DeliveryState.validate_raw_transition(state, "archived"),
               {:ok, archived} <-
                 delivery
                 |> InboundDelivery.state_changeset(%{
                   raw_storage_state: "archived",
                   processing_state: "archived",
                   raw_object_key: key,
                   last_error: nil
                 })
                 |> Repo.update(),
               {:ok, _event} <-
                 delivery.id
                 |> MessageEvent.event_changeset(
                   "archived",
                   %{raw_object_key: key},
                   DateTime.utc_now()
                 )
                 |> Repo.insert(),
               {:ok, _job} <-
                 projection_job_changeset(delivery.id)
                 |> Repo.insert(),
               {:ok, _security_job} <-
                 security_job_changeset(delivery.id)
                 |> Repo.insert() do
            archived
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  @spec ensure_projection_job(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def ensure_projection_job(delivery_id) do
    Repo.transaction(fn ->
      InboundDelivery
      |> where([delivery], delivery.id == ^delivery_id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

      target_args = projection_job_args(delivery_id)

      existing_job =
        Oban.Job
        |> where([job], job.worker == ^inspect(ProjectInboundMail))
        |> where([job], job.state in ~w(available scheduled executing retryable suspended))
        |> where(
          [job],
          fragment("?->>'inbound_delivery_id' = ?", job.args, ^delivery_id)
        )
        |> Repo.all()
        |> Enum.find(fn job ->
          Map.take(job.args, Map.keys(target_args)) == target_args
        end)

      existing_job || projection_job_changeset(delivery_id) |> Repo.insert!()
    end)
  end

  @spec ensure_security_job(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def ensure_security_job(delivery_id) do
    Repo.transaction(fn ->
      InboundDelivery
      |> where([delivery], delivery.id == ^delivery_id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

      target_args = security_job_args(delivery_id)

      existing_job =
        Oban.Job
        |> where([job], job.worker == ^inspect(EvaluateInboundSecurity))
        |> where([job], job.state in ~w(available scheduled executing retryable suspended))
        |> where(
          [job],
          fragment("?->>'inbound_delivery_id' = ?", job.args, ^delivery_id)
        )
        |> Repo.all()
        |> Enum.find(fn job ->
          Map.take(job.args, Map.keys(target_args)) == target_args
        end)

      existing_job || security_job_changeset(delivery_id) |> Repo.insert!()
    end)
  end

  defp cleanup_archived_bundle(%InboundDelivery{} = delivery, opts) do
    raw_store_opts = Keyword.get(opts, :raw_store_opts, [])

    with key when is_binary(key) <- delivery.raw_object_key,
         {:ok, stat} <- RawStore.stat(key, raw_store_opts),
         :ok <- verify_raw_stat(delivery, stat),
         :ok <- remove_spool_bundle_if_present(delivery.spool_bundle_path, opts) do
      :ok
    else
      nil ->
        {:error,
         Error.new(:temporary, :object_store_failed, "archived delivery has no raw object key")}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(:temporary, :object_store_failed, "archived raw object verification failed", %{
           reason: inspect(reason)
         })}
    end
  end

  defp remove_spool_bundle_if_present(path, opts) do
    case file_stat(path, opts) do
      {:ok, _stat} -> Spool.remove_ready_bundle(path)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_spool_file(path, opts) do
    case file_stat(path, opts) do
      {:ok, %{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, :missing_spool}
      {:error, :enoent} -> {:error, :missing_spool}
      {:error, reason} -> {:error, reason}
    end
  end

  defp file_stat(path, opts),
    do: Keyword.get(opts, :file_stat_fun, &File.stat/1).(path)

  defp first_domain_id(delivery_id) do
    DeliveryRecipient
    |> where([r], r.inbound_delivery_id == ^delivery_id)
    |> order_by([r], asc: r.id)
    |> select([r], r.mailbox_id)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> {:error, Error.new(:temporary, :object_store_failed, "delivery has no recipients")}
      mailbox_id -> Accounts.mailbox_domain_id(mailbox_id)
    end
  end

  defp begin_projection(delivery_id, versions) do
    Repo.transaction(fn ->
      delivery =
        InboundDelivery
        |> where([delivery], delivery.id == ^delivery_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      cond do
        is_nil(delivery) ->
          Repo.rollback(Error.new(:permanent, :not_found, "delivery not found"))

        delivery.raw_storage_state != "archived" ->
          Repo.rollback(
            Error.new(:temporary, :raw_not_archived, "raw message is not archived yet")
          )

        delivery.processing_state in ["processed", "parse_failed"] ->
          delivery

        delivery.processing_state == "parsing" ->
          delivery

        true ->
          with :ok <-
                 DeliveryState.validate_processing_transition(
                   delivery.processing_state,
                   "parsing"
                 ),
               {:ok, parsing} <-
                 delivery
                 |> InboundDelivery.state_changeset(%{
                   processing_state: "parsing",
                   last_error: nil
                 })
                 |> Repo.update(),
               {:ok, _event} <-
                 MessageEvent.event_changeset(
                   delivery.id,
                   "parse_started",
                   versions,
                   DateTime.utc_now()
                 )
                 |> Repo.insert() do
            parsing
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
    |> normalize_transaction_error()
  end

  defp finish_projection(delivery_id, projection) do
    Repo.transaction(fn ->
      delivery =
        InboundDelivery
        |> where([delivery], delivery.id == ^delivery_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      target_state = if projection.state == :fallback, do: "parse_failed", else: "processed"
      event_type = if projection.state == :fallback, do: "parse_failed", else: "parsed"

      if delivery.processing_state == target_state do
        delivery
      else
        with :ok <-
               DeliveryState.validate_processing_transition(
                 delivery.processing_state,
                 target_state
               ),
             {:ok, projected} <-
               delivery
               |> InboundDelivery.state_changeset(%{
                 processing_state: target_state,
                 last_error:
                   if(projection.state == :fallback,
                     do: "message projected with MIME parsing fallback",
                     else: nil
                   )
               })
               |> Repo.update(),
             {:ok, _event} <-
               MessageEvent.event_changeset(
                 delivery.id,
                 event_type,
                 %{
                   parser_version: projection.parser_version,
                   sanitizer_version: projection.sanitizer_version
                 },
                 DateTime.utc_now()
               )
               |> Repo.insert() do
          projected
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end)
    |> normalize_transaction_error()
  end

  defp fail_projection(delivery_id, %Error{} = error, versions) do
    Repo.transaction(fn ->
      delivery =
        InboundDelivery
        |> where([delivery], delivery.id == ^delivery_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      if delivery.processing_state == "failed" do
        delivery
      else
        with :ok <-
               DeliveryState.validate_processing_transition(
                 delivery.processing_state,
                 "failed"
               ),
             {:ok, failed} <-
               delivery
               |> InboundDelivery.state_changeset(%{
                 processing_state: "failed",
                 last_error: error.message
               })
               |> Repo.update(),
             {:ok, _event} <-
               MessageEvent.event_changeset(
                 delivery.id,
                 "projection_failed",
                 Map.put(versions, :reason, Atom.to_string(error.reason)),
                 DateTime.utc_now()
               )
               |> Repo.insert() do
          failed
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end)
    |> normalize_transaction_error()
  end

  defp inbound_source(delivery) do
    %InboundSource{
      inbound_delivery_id: delivery.id,
      raw_object_key: delivery.raw_object_key,
      raw_size: delivery.raw_size,
      raw_sha256: delivery.raw_sha256,
      received_at: delivery.received_at
    }
  end

  defp security_input(delivery) do
    %SecurityInput{
      inbound_delivery_id: delivery.id,
      peer_ip: delivery.peer_ip,
      helo: delivery.helo,
      envelope_from: delivery.envelope_from,
      received_at: delivery.received_at,
      raw_object_key: delivery.raw_object_key,
      raw_size: delivery.raw_size,
      raw_sha256: delivery.raw_sha256
    }
  end

  defp validate_security_source(
         %InboundDelivery{raw_storage_state: "archived", raw_object_key: key} = delivery,
         raw_store_opts
       )
       when is_binary(key) do
    case RawStore.stat(key, raw_store_opts) do
      {:ok, stat} -> verify_raw_stat(delivery, stat)
      {:error, reason} -> {:error, raw_verification_error(reason)}
    end
  end

  defp validate_security_source(%InboundDelivery{}, _raw_store_opts) do
    {:error, Error.new(:temporary, :raw_not_archived, "raw message is not archived yet")}
  end

  defp raw_verification_error(reason) do
    Error.new(
      :temporary,
      :raw_verification_failed,
      "archived raw message could not be verified for security evaluation",
      %{reason: inspect(reason)}
    )
  end

  defp projection_job_changeset(delivery_id) do
    delivery_id
    |> projection_job_args()
    |> ProjectInboundMail.new()
  end

  defp projection_job_args(delivery_id) do
    %{
      "inbound_delivery_id" => delivery_id,
      "parser_version" => parser_version(),
      "sanitizer_version" => sanitizer_version()
    }
  end

  defp security_job_changeset(delivery_id) do
    delivery_id
    |> security_job_args()
    |> EvaluateInboundSecurity.new()
  end

  defp security_job_args(delivery_id) do
    %{
      "inbound_delivery_id" => delivery_id,
      "evaluation_version" => security_evaluation_version()
    }
  end

  defp requested_projection_versions(opts) do
    %{
      parser_version: Keyword.get(opts, :parser_version, parser_version()),
      sanitizer_version: Keyword.get(opts, :sanitizer_version, sanitizer_version())
    }
  end

  defp parser_version, do: Application.get_env(:manifold_mail, :parser_version, 1)
  defp sanitizer_version, do: Application.get_env(:manifold_mail, :sanitizer_version, 1)

  defp security_evaluation_version,
    do: Application.get_env(:manifold_security, :evaluation_version, 1)

  defp normalize_transaction_error({:ok, value}), do: {:ok, value}
  defp normalize_transaction_error({:error, %Error{} = error}), do: {:error, error}

  defp normalize_transaction_error({:error, reason}) do
    {:error,
     Error.new(:temporary, :database_unavailable, "mail lifecycle transaction failed", %{
       reason: inspect(reason)
     })}
  end

  defp build_recipient_rows(routes, now) do
    Enum.flat_map(routes, fn route ->
      Enum.map(route.mailbox_ids, fn mailbox_id ->
        %{
          id: Ecto.UUID.generate(),
          original_address: route.original_recipient,
          canonical_address: route.canonical_recipient,
          plus_tag: route.plus_tag,
          mailbox_id: mailbox_id,
          inserted_at: now,
          updated_at: now
        }
      end)
    end)
  end

  defp add_delivery_id(rows, delivery_id),
    do: Enum.map(rows, &Map.put(&1, :inbound_delivery_id, delivery_id))

  defp normalize_route(%_{} = struct), do: struct |> Map.from_struct() |> normalize_route()

  defp normalize_route(map) when is_map(map) do
    %{
      original_recipient: route_field(map, :original_recipient),
      canonical_recipient: route_field(map, :canonical_recipient),
      plus_tag: route_field(map, :plus_tag),
      domain_id: route_field(map, :domain_id),
      mailbox_ids: route_field(map, :mailbox_ids) || []
    }
  end

  defp validate_frozen_routes(%Bundle{manifest: manifest}, routes) do
    manifest_routes =
      case manifest do
        %{routes: manifest_routes} when is_list(manifest_routes) ->
          Enum.map(manifest_routes, &normalize_route/1)

        _ ->
          []
      end

    original_recipients =
      case manifest do
        %{original_recipients: recipients} when is_list(recipients) -> recipients
        _ -> []
      end

    valid_routes? =
      routes != [] and
        Enum.all?(routes, fn route ->
          non_empty_string?(route.original_recipient) and
            non_empty_string?(route.canonical_recipient) and
            non_empty_string?(route.domain_id) and
            is_list(route.mailbox_ids) and route.mailbox_ids != [] and
            Enum.all?(route.mailbox_ids, &non_empty_string?/1) and
            Enum.uniq(route.mailbox_ids) == route.mailbox_ids
        end)

    manifest_matches? =
      manifest_routes == routes and
        original_recipients == Enum.map(routes, & &1.original_recipient)

    if valid_routes? and manifest_matches? do
      :ok
    else
      {:error,
       Error.new(
         :permanent,
         :invalid_routes,
         "frozen recipient routes are empty, invalid, or differ from the spool manifest"
       )}
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and byte_size(value) > 0

  defp route_field(map, field) when is_map(map) do
    Map.get(map, field) || Map.get(map, Atom.to_string(field))
  end

  defp maybe_fault(opts, point) do
    if Keyword.get(opts, :fail_at) == point do
      {:error, Error.new(:temporary, point, "injected ingest fault")}
    else
      :ok
    end
  end
end
