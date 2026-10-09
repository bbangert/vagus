defmodule Vagus.App.Server do
  @moduledoc """
  One process per installed app, registered in `Vagus.App.Directory` under
  `{:slug, slug}` so a second start for the slug fails atomically. It answers
  fact questions by reading `Vagus.Addon.State` and stops `:normal` once its
  entry is gone.

  It owns the app's services and discovery messages and registers
  `{:service, name}` and `{:discovery, uuid}` in the directory with its slug
  as the value, so a unique key is the one-provider-per-service rule and its
  exit drops them all. They are not checkpointed: a restarted process starts
  empty, and until a restart also recreates the container, a container app's
  entries stay gone until it posts them again.
  """

  @behaviour :gen_statem

  alias Vagus.Addon.State
  alias Vagus.App.{Directory, Policy}

  @redacted [:token_hash, :services, :discovery]

  @spec child_spec(String.t()) :: Supervisor.child_spec()
  def child_spec(slug) do
    %{id: {__MODULE__, slug}, start: {__MODULE__, :start_link, [slug]}, restart: :transient}
  end

  @spec start_link(String.t()) :: :gen_statem.start_ret()
  def start_link(slug), do: :gen_statem.start_link(name(slug), __MODULE__, slug, [])

  defp name(slug), do: {:via, Registry, {Directory, {:slug, slug}}}

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init(slug) do
    case State.get(slug) do
      {:ok, _entry} -> {:ok, :idle, %{slug: slug, services: %{}, discovery: %{}}}
      :error -> :ignore
    end
  end

  @impl :gen_statem
  def handle_event({:call, from}, :info, :idle, %{slug: slug}) do
    reply_and_stop_if_gone(from, read(slug), & &1)
  end

  def handle_event({:call, from}, :installed?, :idle, %{slug: slug}) do
    reply_and_stop_if_gone(from, read(slug), &match?({:ok, _entry}, &1))
  end

  # The app's own re-post is refused too, as upstream refuses any second
  # provider: the key is already held.
  def handle_event({:call, from}, {:provide_service, name, payload}, _state, data) do
    case Registry.register(Directory, {:service, name}, data.slug) do
      {:ok, _owner} ->
        data = put_in(data.services[name], payload)
        {:keep_state, data, [{:reply, from, :ok}]}

      {:error, {:already_registered, _pid}} ->
        {:keep_state_and_data, [{:reply, from, {:error, :already_provided}}]}
    end
  end

  def handle_event({:call, from}, {:withdraw_service, name}, _state, data) do
    case Map.pop(data.services, name) do
      {nil, _services} ->
        {:keep_state_and_data, [{:reply, from, {:error, :not_found}}]}

      {_payload, services} ->
        :ok = Registry.unregister(Directory, {:service, name})
        {:keep_state, %{data | services: services}, [{:reply, from, :ok}]}
    end
  end

  def handle_event({:call, from}, {:service, name}, _state, data) do
    {:keep_state_and_data, [{:reply, from, Map.fetch(data.services, name)}]}
  end

  def handle_event({:call, from}, {:add_discovery, service, config}, _state, data) do
    messages = Map.values(data.discovery)
    fresh = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    {outcome, message} = Policy.discover(messages, data.slug, service, config, fresh)

    if outcome == :new,
      do: {:ok, _owner} = Registry.register(Directory, {:discovery, message.uuid}, data.slug)

    data = put_in(data.discovery[message.uuid], message)
    {:keep_state, data, [{:reply, from, {:ok, message, outcome}}]}
  end

  def handle_event({:call, from}, {:delete_discovery, uuid}, _state, data) do
    case Map.pop(data.discovery, uuid) do
      {nil, _discovery} ->
        {:keep_state_and_data, [{:reply, from, {:error, :not_found}}]}

      {message, discovery} ->
        :ok = Registry.unregister(Directory, {:discovery, uuid})
        {:keep_state, %{data | discovery: discovery}, [{:reply, from, {:ok, message}}]}
    end
  end

  def handle_event({:call, from}, {:discovery, uuid}, _state, data) do
    {:keep_state_and_data, [{:reply, from, Map.fetch(data.discovery, uuid)}]}
  end

  def handle_event({:call, from}, :discovery_list, _state, data) do
    {:keep_state_and_data, [{:reply, from, Map.values(data.discovery)}]}
  end

  # A typo'd question from one caller must not crash-loop every app process.
  def handle_event({:call, from}, _question, _state, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :unknown_question}}]}

  # Late replies and stray messages carry nothing this process acts on.
  def handle_event(:info, _message, _state, _data), do: :keep_state_and_data

  # A service payload and a discovery config can carry a password, in the
  # data and in an event that is being handled when the process crashes.
  @impl :gen_statem
  def format_status(status) do
    status
    |> Map.replace_lazy(:data, fn
      data when is_map(data) -> Map.new(data, &redact/1)
      data -> data
    end)
    |> Map.replace_lazy(:queue, fn queue -> Enum.map(queue, &redact_event/1) end)
    |> Map.replace_lazy(:postponed, fn queue -> Enum.map(queue, &redact_event/1) end)
  end

  defp redact({key, _value}) when key in @redacted, do: {key, :redacted}
  defp redact(pair), do: pair

  defp redact_event({type, {:provide_service, name, _payload}}),
    do: {type, {:provide_service, name, :redacted}}

  defp redact_event({type, {:add_discovery, service, _config}}),
    do: {type, {:add_discovery, service, :redacted}}

  defp redact_event(event), do: event

  defp reply_and_stop_if_gone(from, :error, answer),
    do: {:stop_and_reply, :normal, [{:reply, from, answer.(:error)}]}

  defp reply_and_stop_if_gone(from, result, answer),
    do: {:keep_state_and_data, [{:reply, from, answer.(result)}]}

  # A State restart must not crash every app process at once: that many
  # restarts would exhaust `Vagus.App.Instances` and empty the tree.
  defp read(slug) do
    State.get(slug)
  catch
    :exit, _reason -> :unavailable
  end
end
