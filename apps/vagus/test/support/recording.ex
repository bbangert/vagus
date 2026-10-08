defmodule Vagus.Test.Recording do
  @moduledoc """
  A GenServer run by another module's callbacks, under that module's name,
  that tells `report` of every call it has handled: `report.(request,
  reply)`, called here after the call was handled and before its caller
  hears, so what is reported was done, and is reported before anything the
  caller does next.

  It is the process the code under test talks to, so what it reports is
  what arrived there, whoever claims to have sent it.

  `start_link/1` takes `{module, init_arg, name, report}`.
  """

  use GenServer

  def child_spec({module, _arg, name, _report} = arg),
    do: %{id: name, start: {__MODULE__, :start_link, [arg]}, type: type(module)}

  defp type(DynamicSupervisor), do: :supervisor
  defp type(_module), do: :worker

  def start_link({module, arg, name, report}),
    do: GenServer.start_link(__MODULE__, {module, arg, report}, name: name)

  @impl true
  def init({module, arg, report}) do
    with {:ok, inner} <- module.init(arg), do: {:ok, {module, inner, report}}
  end

  @impl true
  def handle_call(request, from, {module, inner, report}) do
    case module.handle_call(request, from, inner) do
      {:reply, reply, inner} ->
        report.(request, reply)
        {:reply, reply, {module, inner, report}}

      {:noreply, inner} ->
        {:noreply, {module, inner, report}}
    end
  end

  @impl true
  def handle_cast(request, {module, inner, report}),
    do: carried(module.handle_cast(request, inner), module, report)

  @impl true
  def handle_info(message, {module, inner, report}),
    do: carried(module.handle_info(message, inner), module, report)

  @impl true
  def terminate(reason, {module, inner, _report}) do
    if function_exported?(module, :terminate, 2), do: module.terminate(reason, inner)
  end

  defp carried({:noreply, inner}, module, report), do: {:noreply, {module, inner, report}}

  defp carried({:stop, reason, inner}, module, report),
    do: {:stop, reason, {module, inner, report}}
end
