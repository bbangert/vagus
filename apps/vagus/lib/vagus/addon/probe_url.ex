defmodule Vagus.Addon.ProbeURL do
  @moduledoc """
  Pure parser/renderer for the `watchdog:`/`webui:` URL-template grammar
  shared by both config knobs (`docs/contract-2026.7-m4b-ingress-watchdog.md`
  §B7.1/§B7.2) — no process, no I/O, fully host-testable.

  The two runtime regexes below are ported **verbatim** from `apps/app.py`'s
  `RE_WATCHDOG`/`RE_WEBUI` (§B7.2); only the named-group syntax changes
  (`(?P<name>...)` is accepted as-is by Erlang's PCRE-backed `Regex`, no
  translation needed — verified against the exact contract strings). Do not
  "clean up" these patterns independently of the contract; if the upstream
  regex changes, update the comment citing it too.

    * `watchdog:` — `tcp://`, `http(s)://`, or `[PROTO:optname]://`, port a
      literal integer or `[PORT:nnnn]`, arbitrary suffix.
    * `webui:` — `http(s)://` or `[PROTO:optname]://` only (no bare `tcp://`
      — it's a browser-navigated display URL, not something Supervisor
      itself connects to), port **must** be the bracketed `[PORT:nnnn]`
      form — no bare-literal-port alternative, unlike watchdog.

  `[HOST]` is a fixed literal in both grammars (matched, never captured) —
  §B7.2 is explicit the two probes treat it completely differently once
  parsed, which is why the two public functions below diverge on what they
  do with it (see each doc for specifics) rather than sharing one render
  path.
  """

  @re_watchdog ~r/^(?:(?P<s_prefix>https?|tcp)|\[PROTO:(?P<t_proto>\w+)\]):\/\/\[HOST\]:(?:\[PORT:)?(?P<t_port>\d+)\]?(?P<s_suffix>.*)$/
  @re_webui ~r/^(?:(?P<s_prefix>https?)|\[PROTO:(?P<t_proto>\w+)\]):\/\/\[HOST\]:\[PORT:(?P<t_port>\d+)\](?P<s_suffix>.*)$/

  @type watchdog_spec :: %{
          proto: String.t(),
          host: String.t(),
          port: integer(),
          suffix: String.t()
        }

  @doc """
  Parses `template` (an add-on's `config.watchdog` string) against the
  runtime probe's own perspective — §B7.2: the watchdog probe runs *inside*
  Supervisor (here: this emulator), so `[HOST]` is fully substituted with
  `host_ip` (the caller's already-resolved container bridge IP; this module
  does no network I/O of its own) and never appears in the returned spec.

  Port resolution (§B7.2 asymmetry): if `config.host_network` **and**
  `config.ports` is non-empty, look up the host-mapped port for
  `"\#{t_port}/tcp"` (falling back to the literal `t_port` if that port isn't
  mapped); otherwise (bridge network — the normal case) use `t_port`
  directly, since this emulator reaches the container by its own bridge IP,
  not a host-published port.

  Protocol resolution (§B7.2): a literal `s_prefix` (`http`/`https`/`tcp`) is
  used as-is; a `[PROTO:optname]` template instead consults
  `options[optname]` (the add-on's own effective option, typically an `ssl`
  boolean) — truthy picks `"https"`, anything else `"http"` (there is no
  `[PROTO:...]` -> `tcp` mapping; the contract's protocol-selection rule
  only ever produces http/https from a proto template).

  Returns `:error` for a template that doesn't match `RE_WATCHDOG` at all
  (should be rare — `Vagus.Addon.Config` already validates the config-time
  grammar at parse time, so this is normally an inconsistency, not user
  input).
  """
  @spec watchdog_spec(String.t(), map(), map(), String.t()) :: {:ok, watchdog_spec()} | :error
  def watchdog_spec(template, config, options, host_ip) when is_binary(template) do
    case Regex.named_captures(@re_watchdog, template) do
      nil ->
        :error

      %{"s_prefix" => s_prefix, "t_proto" => t_proto, "t_port" => t_port, "s_suffix" => suffix} ->
        {:ok,
         %{
           proto: proto(s_prefix, t_proto, options),
           host: host_ip,
           port: watchdog_port(config, t_port),
           suffix: suffix
         }}
    end
  end

  @doc """
  Renders `config.webui` (a `webui:` template string, or `nil`) to the
  display URL Core/the frontend expect, or `nil`.

  Unlike `watchdog_spec/4`, `[HOST]` is **deliberately left as the literal
  string `"[HOST]"`** in the output (§B7.2 fact 8) — a webui link is
  navigated to directly by the user's own browser, bypassing this emulator
  entirely, so only the frontend (which knows its own current hostname) can
  fill it in. Do not "fix" this by substituting a real host here.

  Port lookup is **unconditional** (§B7.2 — no `host_network` branch, unlike
  `watchdog_spec/4`): `config.ports["\#{t_port}/tcp"] || t_port` always,
  because a webui link is always resolved from the browser's perspective
  (no bridge access either way), regardless of the add-on's network mode.

  `nil` template, or a template that doesn't match `RE_WEBUI` (e.g. it uses
  a bare literal port, valid for `watchdog:` but not `webui:`), both render
  `nil`.
  """
  @spec webui_url(String.t() | nil, map(), map()) :: String.t() | nil
  def webui_url(nil, _config, _options), do: nil

  def webui_url(template, config, options) when is_binary(template) do
    case Regex.named_captures(@re_webui, template) do
      nil ->
        nil

      %{"s_prefix" => s_prefix, "t_proto" => t_proto, "t_port" => t_port, "s_suffix" => suffix} ->
        proto = proto(s_prefix, t_proto, options)
        port = Map.get(config.ports, "#{t_port}/tcp") || String.to_integer(t_port)
        "#{proto}://[HOST]:#{port}#{suffix}"
    end
  end

  ## Internals

  # `s_prefix` empty means the template used `[PROTO:optname]` instead (the
  # two alternatives in the regex are mutually exclusive by construction).
  defp proto("", t_proto, options) when t_proto != "" do
    if truthy?(Map.get(options, t_proto)), do: "https", else: "http"
  end

  defp proto(s_prefix, _t_proto, _options), do: s_prefix

  defp truthy?(true), do: true
  defp truthy?(_other), do: false

  # §B7.2 port asymmetry: watchdog special-cases `host_network` — bridge-mode
  # add-ons (the common case) are reached directly on their container port,
  # since this emulator sits on the same bridge network; only a
  # host-networked add-on needs the host-published port instead (there is no
  # bridge IP to reach it by).
  defp watchdog_port(%{host_network: true, ports: ports}, t_port) when map_size(ports) > 0 do
    Map.get(ports, "#{t_port}/tcp") || String.to_integer(t_port)
  end

  defp watchdog_port(_config, t_port), do: String.to_integer(t_port)
end
