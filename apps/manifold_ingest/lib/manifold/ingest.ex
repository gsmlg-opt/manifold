defmodule Manifold.Ingest do
  @moduledoc """
  Inbound SMTP acceptance, lifecycle, and archival APIs.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Manifold.Accounts
  alias Manifold.Core.{DeliveryState, Error}
  alias Manifold.Ingest.{AcceptanceReceipt, ExternalAcceptanceReceipt, ExternalSource}
  alias Manifold.Ingest.Jobs.{ArchiveRawEmail, EvaluateInboundSecurity, ProjectInboundMail}

  alias Manifold.Ingest.Schema.{
    CloudIngressIdentity,
    DeliveryRecipient,
    ExternalIngressIdentity,
    InboundDelivery,
    MessageEvent
  }

  alias Manifold.Mail
  alias Manifold.Mail.InboundSource
  alias Manifold.Ingest.View.DeliveryDetail
  alias Manifold.Repo
  alias Manifold.Security
  alias Manifold.Security.Input, as: SecurityInput
  alias Manifold.Storage.{RawStore, Spool}
  alias Manifold.Storage.Spool.{Bundle, Manifest}

  @type accept_result :: {:ok, InboundDelivery.t()} | {:error, Error.t()}
  @type edge_accept_result :: {:ok, AcceptanceReceipt.t()} | {:error, Error.t()}
  @type external_accept_result ::
          {:ok, ExternalAcceptanceReceipt.t()} | {:error, Error.t()}

  @spec accept_transport(binary(), map(), [map() | struct()], Keyword.t()) :: accept_result()
  def accept_transport(raw, attrs, frozen_routes, opts \\ []) when is_binary(raw) do
    spool_opts = Keyword.get(opts, :spool_opts, [])

    spool_attrs =
      attrs
      |> Map.put(:routes, frozen_routes)
      |> Map.put_new(:source_kind, "smtp")
      |> Map.put_new(:storage_domain_id, first_route_domain_id(frozen_routes))
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

  @doc """
  Durably imports an immutable raw message from an external mailbox provider.

  Provider imports intentionally create no SMTP delivery-recipient facts.
  Repeating the same provider identity returns the original receipt when the
  raw content and target mailbox match.
  """
  @spec import_external(binary(), ExternalSource.t(), Keyword.t()) :: external_accept_result()
  def import_external(raw, %ExternalSource{} = source, opts \\ []) when is_binary(raw) do
    fingerprint = external_fingerprint(source, raw)

    with :ok <- validate_external_source(source),
         :ok <- validate_external_mailbox(source) do
      case fetch_external_identity(source) do
        nil ->
          with {:ok, bundle} <- external_bundle(raw, source, opts) do
            persist_external_acceptance(bundle, source, fingerprint, opts)
          end

        identity ->
          verify_existing_external(identity, fingerprint)
      end
    end
  rescue
    DBConnection.ConnectionError ->
      {:error,
       Error.new(:temporary, :database_unavailable, "database is temporarily unavailable")}
  end

  @doc """
  Finds an already committed provider acceptance by its trusted source identity.
  """
  @spec lookup_external(String.t(), String.t(), String.t()) :: external_accept_result()
  def lookup_external(provider, source_id, external_message_id)
      when is_binary(provider) and is_binary(source_id) and is_binary(external_message_id) do
    case fetch_external_identity(provider, source_id, external_message_id) do
      %ExternalIngressIdentity{} = identity ->
        {:ok, external_receipt(identity, true)}

      nil ->
        {:error,
         Error.new(
           :permanent,
           :external_ingress_not_found,
           "external ingress identity was not found"
         )}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error,
       Error.new(:temporary, :database_unavailable, "database is temporarily unavailable")}
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

  @doc """
  Atomically accepts an edge delivery and records its external identity.

  Repeating an accepted source and external delivery ID returns the original
  receipt when the raw content and frozen routes match.
  """
  @spec accept_edge(String.t(), String.t(), Bundle.t(), [map() | struct()]) ::
          edge_accept_result()
  @spec accept_edge(String.t(), String.t(), Bundle.t(), [map() | struct()], Keyword.t()) ::
          edge_accept_result()
  def accept_edge(source_id, external_delivery_id, bundle, frozen_routes, opts \\ [])

  def accept_edge(
        source_id,
        external_delivery_id,
        %Bundle{} = bundle,
        frozen_routes,
        opts
      )
      when is_list(frozen_routes) do
    routes = Enum.map(frozen_routes, &normalize_route/1)

    with :ok <- validate_ingress_identity(source_id, external_delivery_id),
         :ok <- validate_frozen_routes(bundle, routes) do
      fingerprint = ingress_fingerprint(bundle, routes)

      case fetch_ingress_identity(source_id, external_delivery_id) do
        nil ->
          persist_edge_acceptance(
            source_id,
            external_delivery_id,
            bundle,
            routes,
            fingerprint,
            opts
          )

        identity ->
          verify_existing_ingress(identity, fingerprint)
      end
    end
  rescue
    DBConnection.ConnectionError ->
      {:error,
       Error.new(:temporary, :database_unavailable, "database is temporarily unavailable")}
  end

  @doc """
  Looks up the durable receipt for an edge delivery identity.
  """
  @spec lookup_ingress(String.t(), String.t()) :: edge_accept_result()
  def lookup_ingress(source_id, external_delivery_id) do
    with :ok <- validate_ingress_identity(source_id, external_delivery_id),
         %CloudIngressIdentity{} = identity <-
           fetch_ingress_identity(source_id, external_delivery_id) do
      {:ok, acceptance_receipt(identity, true)}
    else
      nil -> {:error, Error.new(:permanent, :not_found, "edge ingress identity not found")}
      {:error, %Error{} = error} -> {:error, error}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error,
       Error.new(:temporary, :database_unavailable, "database is temporarily unavailable")}
  end

  defp persist_acceptance(bundle, routes, opts) do
    case Repo.transaction(acceptance_multi(bundle, routes, opts)) do
      {:ok, %{delivery: delivery}} ->
        emit_acceptance_telemetry(delivery)
        {:ok, delivery}

      transaction_error ->
        normalize_acceptance_error(transaction_error)
    end
  end

  defp persist_edge_acceptance(
         source_id,
         external_delivery_id,
         bundle,
         routes,
         fingerprint,
         opts
       ) do
    edge_opts = Keyword.put(opts, :source_kind, "edge_smtp")

    multi =
      bundle
      |> acceptance_multi(routes, edge_opts)
      |> Multi.insert(:cloud_ingress_identity, fn %{delivery: delivery} ->
        CloudIngressIdentity.changeset(%CloudIngressIdentity{}, %{
          source_id: source_id,
          external_delivery_id: external_delivery_id,
          inbound_delivery_id: delivery.id,
          raw_sha256: fingerprint.raw_sha256,
          raw_size: fingerprint.raw_size,
          routes_sha256: fingerprint.routes_sha256
        })
      end)

    case Repo.transaction(multi) do
      {:ok, %{delivery: delivery, cloud_ingress_identity: identity}} ->
        emit_acceptance_telemetry(delivery)
        {:ok, acceptance_receipt(%{identity | inbound_delivery: delivery}, false)}

      transaction_error ->
        case fetch_ingress_identity(source_id, external_delivery_id) do
          %CloudIngressIdentity{} = identity ->
            verify_existing_ingress(identity, fingerprint)

          nil ->
            normalize_acceptance_error(transaction_error)
        end
    end
  end

  defp persist_external_acceptance(bundle, source, fingerprint, opts) do
    now = DateTime.utc_now()

    multi =
      Multi.new()
      |> Multi.insert(
        :delivery,
        InboundDelivery.acceptance_changeset(%InboundDelivery{}, bundle, %{
          source_kind: "provider_import",
          storage_domain_id: source.storage_domain_id
        })
      )
      |> Multi.run(:maybe_fail_after_delivery, fn _repo, _changes ->
        case maybe_fault(opts, :after_delivery_insert_before_commit) do
          :ok -> {:ok, :ok}
          {:error, error} -> {:error, error}
        end
      end)
      |> Mail.add_external_acceptance_entry(
        :mailbox_entry,
        :delivery,
        source.mailbox_id,
        source.recipient_address,
        now
      )
      |> Multi.insert(:accepted_event, fn %{delivery: delivery} ->
        MessageEvent.event_changeset(
          delivery.id,
          "accepted",
          %{
            source_kind: "provider_import",
            provider: source.provider,
            source_id: source.account_id,
            external_message_id: source.external_message_id
          },
          now
        )
      end)
      |> Multi.insert(:archive_job, fn %{delivery: delivery} ->
        ArchiveRawEmail.new(%{"inbound_delivery_id" => delivery.id})
      end)
      |> Multi.insert(:external_ingress_identity, fn %{delivery: delivery} ->
        ExternalIngressIdentity.changeset(%ExternalIngressIdentity{}, %{
          provider: source.provider,
          source_id: source.account_id,
          external_message_id: source.external_message_id,
          inbound_delivery_id: delivery.id,
          mailbox_id: source.mailbox_id,
          raw_size: fingerprint.raw_size,
          raw_sha256: fingerprint.raw_sha256,
          target_sha256: fingerprint.target_sha256
        })
      end)

    case Repo.transaction(multi) do
      {:ok, %{delivery: delivery, external_ingress_identity: identity}} ->
        emit_acceptance_telemetry(delivery)
        {:ok, external_receipt(%{identity | inbound_delivery: delivery}, false)}

      transaction_error ->
        case fetch_external_identity(source) do
          %ExternalIngressIdentity{} = identity ->
            verify_existing_external(identity, fingerprint)

          nil ->
            normalize_acceptance_error(transaction_error)
        end
    end
  end

  defp acceptance_multi(bundle, routes, opts) do
    now = DateTime.utc_now()
    recipient_rows = build_recipient_rows(routes, now)
    source_kind = Keyword.get(opts, :source_kind, "smtp")
    storage_domain_id = Keyword.get(opts, :storage_domain_id, first_route_domain_id(routes))

    Multi.new()
    |> Multi.insert(
      :delivery,
      InboundDelivery.acceptance_changeset(%InboundDelivery{}, bundle, %{
        source_kind: source_kind,
        storage_domain_id: storage_domain_id
      })
    )
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
      Enum.map(delivery.delivery_recipients, & &1.mailbox_id)
      |> Kernel.++(
        ExternalIngressIdentity
        |> where([identity], identity.inbound_delivery_id == ^delivery.id)
        |> select([identity], identity.mailbox_id)
        |> Repo.all()
      )
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
    case Repo.get(InboundDelivery, delivery_id) do
      %InboundDelivery{storage_domain_id: domain_id} when is_binary(domain_id) ->
        {:ok, domain_id}

      _delivery ->
        DeliveryRecipient
        |> where([r], r.inbound_delivery_id == ^delivery_id)
        |> order_by([r], asc: r.id)
        |> select([r], r.mailbox_id)
        |> limit(1)
        |> Repo.one()
        |> case do
          nil ->
            {:error,
             Error.new(:temporary, :object_store_failed, "delivery has no storage domain")}

          mailbox_id ->
            Accounts.mailbox_domain_id(mailbox_id)
        end
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
      raw_sha256: delivery.raw_sha256,
      source_kind: delivery.source_kind
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

  defp fetch_ingress_identity(source_id, external_delivery_id) do
    CloudIngressIdentity
    |> Repo.get_by(source_id: source_id, external_delivery_id: external_delivery_id)
    |> Repo.preload(:inbound_delivery)
  end

  defp verify_existing_ingress(identity, fingerprint) do
    if ingress_fingerprint(identity) == fingerprint do
      {:ok, acceptance_receipt(identity, true)}
    else
      {:error,
       Error.new(
         :permanent,
         :ingress_conflict,
         "edge delivery identity conflicts with the previously accepted content or routes"
       )}
    end
  end

  defp acceptance_receipt(identity, existing?) do
    %AcceptanceReceipt{
      source_id: identity.source_id,
      external_delivery_id: identity.external_delivery_id,
      inbound_delivery_id: identity.inbound_delivery_id,
      ingest_id: identity.inbound_delivery.ingest_id,
      raw_sha256: identity.raw_sha256,
      raw_size: identity.raw_size,
      routes_sha256: identity.routes_sha256,
      existing?: existing?
    }
  end

  defp ingress_fingerprint(%Bundle{manifest: manifest}, routes) do
    %{
      raw_sha256: manifest.raw_sha256,
      raw_size: manifest.raw_size,
      routes_sha256: routes_sha256(routes)
    }
  end

  defp ingress_fingerprint(%CloudIngressIdentity{} = identity) do
    %{
      raw_sha256: identity.raw_sha256,
      raw_size: identity.raw_size,
      routes_sha256: identity.routes_sha256
    }
  end

  defp routes_sha256(routes) do
    canonical_routes =
      Enum.map(routes, fn route ->
        {
          route.original_recipient,
          route.canonical_recipient,
          route.plus_tag,
          route.domain_id,
          route.mailbox_ids
        }
      end)

    canonical_routes
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp validate_ingress_identity(source_id, external_delivery_id) do
    if valid_ingress_id?(source_id) and valid_ingress_id?(external_delivery_id) do
      :ok
    else
      {:error,
       Error.new(
         :permanent,
         :invalid_ingress_identity,
         "edge source and external delivery IDs must be non-empty strings up to 255 bytes"
       )}
    end
  end

  defp valid_ingress_id?(value) do
    is_binary(value) and value == String.trim(value) and value != "" and byte_size(value) <= 255
  end

  defp emit_acceptance_telemetry(delivery) do
    :telemetry.execute(
      [:manifold, :ingest, :accept, :stop],
      %{raw_size: delivery.raw_size},
      %{
        ingest_id: delivery.ingest_id,
        delivery_id: delivery.id
      }
    )
  end

  defp normalize_acceptance_error({:error, _step, %Error{} = error, _changes}),
    do: {:error, error}

  defp normalize_acceptance_error({:error, _step, reason, _changes}) do
    {:error,
     Error.new(:temporary, :acceptance_failed, "acceptance transaction failed", %{
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

  defp first_route_domain_id([route | _rest]), do: route_field(route, :domain_id)
  defp first_route_domain_id([]), do: nil

  defp validate_external_source(%ExternalSource{} = source) do
    valid_provider? = source.provider in ["gmail", "microsoft", "imap"]

    valid_ids? =
      Enum.all?(
        [
          {source.account_id, 255},
          {source.external_message_id, 512},
          {source.mailbox_id, 255},
          {source.storage_domain_id, 255},
          {source.recipient_address, 998},
          {source.ingest_id, 255}
        ],
        fn {value, max_bytes} ->
          is_binary(value) and value != "" and value == String.trim(value) and
            byte_size(value) <= max_bytes
        end
      )

    if valid_provider? and valid_ids? and match?(%DateTime{}, source.received_at) do
      :ok
    else
      {:error,
       Error.new(
         :permanent,
         :invalid_external_source,
         "external message source is invalid"
       )}
    end
  end

  defp validate_external_mailbox(source) do
    case Accounts.active_mailbox_domain_id(source.mailbox_id) do
      {:ok, domain_id} when domain_id == source.storage_domain_id ->
        :ok

      {:ok, _other_domain_id} ->
        {:error,
         Error.new(
           :permanent,
           :external_target_mismatch,
           "external target mailbox does not belong to the storage domain"
         )}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp external_bundle(raw, source, opts) do
    spool_opts = Keyword.get(opts, :spool_opts, [])
    root = Keyword.get(spool_opts, :root, Spool.spool_root())
    bundle = Spool.bundle_for(root, source.ingest_id)

    case File.stat(bundle.path) do
      {:ok, %{type: :directory}} ->
        load_external_bundle(bundle, source, raw)

      {:error, :enoent} ->
        attrs = %{
          source_kind: "provider_import",
          external_provider: source.provider,
          external_source_id: source.account_id,
          external_message_id: source.external_message_id,
          storage_domain_id: source.storage_domain_id,
          target_mailbox_id: source.mailbox_id,
          received_at: source.received_at,
          peer_ip: nil,
          helo: nil,
          envelope_from: nil,
          original_recipients: [],
          routes: []
        }

        Spool.write_bundle(
          raw,
          attrs,
          Keyword.put(spool_opts, :ingest_id, source.ingest_id)
        )

      {:ok, _other} ->
        external_bundle_error(:invalid_ready_bundle)

      {:error, reason} ->
        {:error,
         Error.new(:temporary, :spool_failed, "external spool status failed", %{
           reason: inspect(reason)
         })}
    end
  end

  defp load_external_bundle(bundle, source, raw) do
    expected_sha256 = Manifest.sha256(raw)

    with {:ok, manifest} <- Spool.read_manifest(bundle.path),
         {:ok, stat} <- File.stat(bundle.raw_path),
         {:ok, actual_sha256} <- Manifest.sha256_file(bundle.raw_path),
         true <-
           manifest.version == 2 and
             manifest.ingest_id == source.ingest_id and
             manifest.ingest_id == Path.basename(bundle.path) and
             manifest.source_kind == "provider_import" and
             manifest.external_provider == source.provider and
             manifest.external_source_id == source.account_id and
             manifest.external_message_id == source.external_message_id and
             manifest.storage_domain_id == source.storage_domain_id and
             manifest.target_mailbox_id == source.mailbox_id and
             manifest.raw_size == byte_size(raw) and
             manifest.raw_size == stat.size and
             manifest.raw_sha256 == expected_sha256 and
             manifest.raw_sha256 == actual_sha256 do
      {:ok, %{bundle | manifest: manifest}}
    else
      false -> external_bundle_error(:ready_bundle_conflict)
      {:error, reason} -> external_bundle_error(reason)
    end
  end

  defp external_bundle_error(reason) do
    {:error,
     Error.new(
       :permanent,
       :external_ready_conflict,
       "existing external ready bundle does not match the provider message",
       %{reason: inspect(reason)}
     )}
  end

  defp external_fingerprint(source, raw) do
    %{
      raw_size: byte_size(raw),
      raw_sha256: Manifest.sha256(raw),
      target_sha256: external_target_sha256(source)
    }
  end

  defp external_target_sha256(source) do
    {
      source.mailbox_id,
      source.storage_domain_id,
      source.recipient_address
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp fetch_external_identity(source) do
    fetch_external_identity(source.provider, source.account_id, source.external_message_id)
  end

  defp fetch_external_identity(provider, source_id, external_message_id) do
    ExternalIngressIdentity
    |> Repo.get_by(
      provider: provider,
      source_id: source_id,
      external_message_id: external_message_id
    )
    |> Repo.preload(:inbound_delivery)
  end

  defp verify_existing_external(identity, fingerprint) do
    existing = %{
      raw_size: identity.raw_size,
      raw_sha256: identity.raw_sha256,
      target_sha256: identity.target_sha256
    }

    if existing == fingerprint do
      {:ok, external_receipt(identity, true)}
    else
      {:error,
       Error.new(
         :permanent,
         :external_ingress_conflict,
         "provider message identity conflicts with previously accepted content or target"
       )}
    end
  end

  defp external_receipt(identity, existing?) do
    %ExternalAcceptanceReceipt{
      provider: identity.provider,
      source_id: identity.source_id,
      external_message_id: identity.external_message_id,
      inbound_delivery_id: identity.inbound_delivery_id,
      ingest_id: identity.inbound_delivery.ingest_id,
      raw_sha256: identity.raw_sha256,
      raw_size: identity.raw_size,
      target_sha256: identity.target_sha256,
      existing?: existing?
    }
  end

  defp maybe_fault(opts, point) do
    if Keyword.get(opts, :fail_at) == point do
      {:error, Error.new(:temporary, point, "injected ingest fault")}
    else
      :ok
    end
  end
end
