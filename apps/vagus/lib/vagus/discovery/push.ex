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
  returns `:ok` — the actual request runs in a detached task (`deliver/3`).

  `opts[:request_fun]` overrides the Core request function (arity 3, matching
  `Vagus.Core.Client.request/3`); used by tests to drive `deliver/3`'s branches
  synchronously without a live Core.
  """
  @spec push(:post | :delete, message(), keyword()) :: :ok
  def push(method, message, opts \\ []) do
    request_fun = Keyword.get(opts, :request_fun, &Vagus.Core.Client.request/3)
    Task.start(fn -> deliver(method, message, request_fun) end)
    :ok
  end

  @doc """
  The synchronous body of one push — issues the Core request via `request_fun`
  and logs per outcome. Exposed (not private) only so tests can exercise every
  branch deterministically; production always reaches it through `push/3`'s
  detached task.

  `request_fun` is expected to return a tagged tuple, but a misbehaving call must
  not kill the detached task with only a default crash report: an exception is
  `rescue`d and an exit (e.g. a `GenServer.call` to an unstarted
  `Vagus.Core.Client`, which exits `:noproc`) is `catch`ed — both logged and
  swallowed like any other push failure.
  """
  @spec deliver(:post | :delete, message(), (atom(), String.t(), keyword() -> term())) :: :ok
  def deliver(method, %{uuid: uuid, addon: addon, service: service}, request_fun) do
    body = Jason.encode!(%{"addon" => addon, "service" => service, "uuid" => uuid})

    case request_fun.(method, "/api/hassio_push/discovery/#{uuid}",
           headers: [{"content-type", "application/json"}],
           body: body
         ) do
      {:ok, _response} ->
        :ok

      {:error, :no_refresh_token} ->
        Logger.debug("Vagus.Discovery.Push: discovery #{method} not pushed — Core not connected")

      {:error, reason} ->
        Logger.warning(
          "Vagus.Discovery.Push: discovery #{method} push for #{uuid} failed: #{inspect(reason)}"
        )
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "Vagus.Discovery.Push: discovery #{method} push for #{uuid} crashed: " <>
          Exception.message(e)
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "Vagus.Discovery.Push: discovery #{method} push for #{uuid} exited: #{inspect(reason)}"
      )

      :ok
  end
end
