defmodule Vagus.App.Probe do
  @moduledoc """
  One URL-watchdog probe of an app (upstream `watchdog_application`), run in
  the app process's probe task. A template that does not render, or an app
  with no address to dial, is `:skip`: the probe could not be run, which is
  not evidence that the app is unhealthy.

  `https` is probed without certificate verification, as upstream does: a
  self-signed certificate is the common case, and the question is only
  whether something answers.
  """

  require Logger

  alias Vagus.Addon.ProbeURL
  alias Vagus.Network

  @tcp_connect_timeout_ms 10_000
  @probe_timeout_ms 10_000

  @spec check(String.t() | nil, map()) :: :healthy | :unhealthy | :skip
  def check(template, %{config: config, user_options: options} = data)
      when is_binary(template) do
    with {:ok, %{port: port}} <- ProbeURL.watchdog_spec(template, config, options, ""),
         {:ok, ip} <- address(config, data, port),
         {:ok, spec} <- ProbeURL.watchdog_spec(template, config, options, ip) do
      probe(spec)
    else
      _no_spec_or_address -> :skip
    end
  end

  def check(_template, _data), do: :skip

  # A host-network app answers on loopback or on the gateway depending on the
  # app, so the probed port decides, as for its ingress target.
  defp address(%{host_network: true}, _data, port), do: {:ok, Network.host_network_ip(port)}
  defp address(_config, %{ip: ip}, _port) when is_binary(ip), do: {:ok, ip}
  defp address(_config, _data, _port), do: :error

  defp probe(%{proto: "tcp", host: host, port: port}) do
    case :gen_tcp.connect(String.to_charlist(host), port, [], @tcp_connect_timeout_ms) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :healthy

      {:error, _reason} ->
        :unhealthy
    end
  end

  defp probe(%{proto: proto, host: host, port: port, suffix: suffix})
       when proto in ["http", "https"] do
    path = if suffix == "", do: "/", else: suffix

    case one_shot_get(scheme(proto), host, port, path) do
      {:ok, status} when is_integer(status) and status < 300 -> :healthy
      _ -> :unhealthy
    end
  rescue
    # Whatever the probe hit (a malformed host, a Mint edge), the app did not
    # answer healthily: a miss, logged so the cause is not lost.
    e ->
      Logger.debug("Vagus.App.Probe: probe raised (#{Exception.message(e)})")
      :unhealthy
  catch
    _kind, _reason -> :unhealthy
  end

  defp scheme("http"), do: :http
  defp scheme("https"), do: :https

  defp one_shot_get(scheme, host, port, path) do
    deadline = System.monotonic_time(:millisecond) + @probe_timeout_ms

    with {:ok, connect_timeout} <- remaining(deadline),
         {:ok, conn} <-
           Mint.HTTP.connect(scheme, host, port, connect_opts(scheme, connect_timeout)) do
      try do
        with {:ok, conn, ref} <- Mint.HTTP.request(conn, "GET", path, [], ""),
             {:ok, status} <- await_status(conn, ref, deadline) do
          {:ok, status}
        else
          _ -> :error
        end
      after
        Mint.HTTP.close(conn)
      end
    else
      _ -> :error
    end
  end

  defp connect_opts(:https, timeout),
    do: [mode: :passive, timeout: timeout, transport_opts: [verify: :verify_none]]

  defp connect_opts(:http, timeout), do: [mode: :passive, timeout: timeout]

  defp await_status(conn, ref, deadline) do
    with {:ok, timeout} <- remaining(deadline),
         {:ok, conn, responses} <- recv(conn, timeout) do
      case Enum.find_value(responses, &status(&1, ref)) do
        nil -> await_status(conn, ref, deadline)
        status -> {:ok, status}
      end
    end
  end

  defp recv(conn, timeout) do
    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, responses} -> {:ok, conn, responses}
      {:error, _conn, _reason, _responses} -> :error
    end
  end

  defp status({:status, ref, status}, ref), do: status
  defp status(_response, _ref), do: nil

  defp remaining(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      ms when ms > 0 -> {:ok, ms}
      _ -> :error
    end
  end
end
