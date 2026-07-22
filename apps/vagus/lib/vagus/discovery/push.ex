defmodule Vagus.Discovery.Push do
  @moduledoc """
  Fire-and-forget push of a discovery add/remove to Core
  (`POST|DELETE api/hassio_push/discovery/{uuid}`) so Core live-reconfigures a
  config flow immediately, instead of only picking the change up on its next
  boot-time `GET /discovery` pull (§A3.2).

  Shared by both discovery publishers: `Vagus.API.Router` (a container add-on
  POSTing `/discovery`) and `Vagus.Mqtt.Broker.Provider` (the native broker,
  which registers `mqtt` in-process rather than over HTTP).

  Best-effort and decoupled via `Task.start/1` — the caller never blocks on a
  Core round-trip. Until the Core handshake has happened,
  `Vagus.Core.Client.request/3` returns `{:error, :no_refresh_token}`; that is
  the expected case when a publisher registers before Core is up (the native
  broker boots ahead of Core), and Core's boot-time pull then covers it, so it
  is logged only at debug. Other errors are logged as warnings.
  """

  require Logger

  @type message :: %{
          required(:uuid) => String.t(),
          required(:addon) => String.t(),
          required(:service) => String.t(),
          optional(any()) => any()
        }

  @doc """
  Pushes `message` (add via `:post`, remove via `:delete`) to Core. Always
  returns `:ok` — the actual request runs in a detached task.
  """
  @spec push(:post | :delete, message()) :: :ok
  def push(method, %{uuid: uuid, addon: addon, service: service}) do
    body = Jason.encode!(%{"addon" => addon, "service" => service, "uuid" => uuid})

    Task.start(fn ->
      case Vagus.Core.Client.request(method, "/api/hassio_push/discovery/#{uuid}",
             headers: [{"content-type", "application/json"}],
             body: body
           ) do
        {:ok, _response} ->
          :ok

        {:error, :no_refresh_token} ->
          Logger.debug(
            "Vagus.Discovery.Push: discovery #{method} not pushed — Core not connected"
          )

        {:error, reason} ->
          Logger.warning(
            "Vagus.Discovery.Push: discovery #{method} push for #{uuid} failed: #{inspect(reason)}"
          )
      end
    end)

    :ok
  end
end
