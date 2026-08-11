defmodule Vagus.API.PermissionMatrixTest do
  @moduledoc """
  Does Vagus admit and refuse the same paths a real Supervisor does, for the
  same declared permissions?

  `Vagus.API.Tiers`' `@table` was transcribed by hand from upstream's
  `security.py`. Hand transcription is exactly what produced the 26-route audit
  finding, and a test that restates the table back to itself would have stayed
  green through it. So this compares against
  `test/fixtures/haos-2026.07.5-permission-matrix.json` — captured from a real
  Home Assistant Green by installing one add-on per permission set and asking
  each what it could reach.

  ## The comparison axis is deliberately binary

  Only `denied` (401/403) versus `permitted` (anything else) is asserted, and
  that is not laziness in either direction.

  It cannot be finer, because the probe's own `:refused`/`:rejected` split does
  not survive the crossing: it keys off whether the body carried an API error
  envelope, and Vagus answers refusals *with* that envelope
  (`%{"result" => "error", "message" => "unauthorized"}`) where upstream raises
  a bare framework exception. Comparing those classes directly would mark every
  denied path as a divergence and teach everyone to ignore the test.

  It should not be coarser, because "did this credential get past the lattice"
  is the whole question. A path that authorizes may then answer 200, 405, 404 or
  502 depending on whether Core is up, whether a slug exists, or whether the
  verb was one the route registers — all environmental, none of it a statement
  about permission. Folding them together is what makes the assertion stable
  outside a live device.

  ## Regenerating the fixture

  Requires the bench: install the `probe_*` add-ons from the bench add-on
  repository, then per add-on `POST /eval` with `Jason.encode!(report())` and
  collect the rows. Each row records the Supervisor version it came from, and
  the filename must agree with it.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias Vagus.Addon.Registry
  alias Vagus.API.Dispatcher

  @fixture_path Path.join([
                  __DIR__,
                  "..",
                  "..",
                  "fixtures",
                  "haos-2026.07.5-permission-matrix.json"
                ])
  @external_resource @fixture_path
  @fixture @fixture_path |> File.read!() |> Jason.decode!()

  @supervisor_version @fixture_path
                      |> Path.basename()
                      |> String.replace_prefix("haos-", "")
                      |> String.replace_suffix("-permission-matrix.json", "")

  @opts Dispatcher.init([])

  # Divergences reviewed and accepted, by path. Being STRICTER than upstream is
  # a standing allowance in this codebase; being LOOSER never is, and acceptance
  # therefore applies ONLY to the stricter direction — an accepted path that
  # later starts admitting what upstream refuses still fails. Every entry needs
  # a reason, so acceptance stays a decision rather than decaying into a
  # silenced failure.
  @accepted %{
    # `Vagus.API.Router.resolve_info_slug/2` admits only `self` or the caller's
    # own slug for an add-on caller, whatever its role. Upstream role-gates
    # these instead, so a manager add-on there may read another add-on and gets
    # 404 for one that does not exist. Deliberate here, and relied on: the
    # reserved admin-panel slug is documented as answering the byte-identical
    # 403 a foreign slug produces, which only holds while foreign slugs 403.
    "/addons/_slug/info" => "add-on callers may only read their own slug",
    "/addons/_slug/logs" => "add-on callers may only read their own slug",
    "/addons/_slug/options" => "supervisor-only in @table; upstream allows manager",

    # The block in `Vagus.API.Tiers.@table` headed "Vagus stricter than
    # upstream: supervisor-only (deliberate)" — routes the router already gated
    # with `supervisor_only/2`, kept at the tier they shipped with.
    "/host/disks/default/usage" => "supervisor-only by deliberate table entry",
    "/os/datadisk/list" => "supervisor-only by deliberate table entry",
    "/store/addons/_slug/changelog" => "supervisor-only by deliberate table entry",
    "/store/addons/_slug/documentation" => "supervisor-only by deliberate table entry"
  }

  test "the fixture records the Supervisor version its filename claims" do
    assert @fixture["_supervisor"] == @supervisor_version
    assert @fixture["versions"]["supervisor"] == @supervisor_version
  end

  test "every permission set admits and refuses what the real Supervisor does" do
    divergences =
      for {key, variant} <- @fixture["variants"],
          {path, haos} <- variant["matrix"],
          divergence = compare(key, variant, path, haos),
          do: divergence

    {stricter, looser} = Enum.split_with(divergences, &(&1.vagus == :denied))

    # Suppression applies to the stricter direction only. A path accepted as
    # "deliberately stricter" that later starts admitting what upstream refuses
    # is a regression, and must not be silenced by its own acceptance entry.
    assert looser == [], """
    Vagus permits paths the real Supervisor refuses.

    #{format(looser)}
    """

    stricter = Enum.reject(stricter, &Map.has_key?(@accepted, &1.path))

    assert stricter == [], """
    Vagus refuses paths the real Supervisor permits.

    Stricter than upstream is an allowed outcome in this codebase, but it is a
    decision, not a default: add each to @accepted with a reason, or fix it.

    #{format(stricter)}
    """
  end

  defp compare(key, variant, path, haos) do
    haos_verdict = verdict(haos["status"])
    vagus_status = request(key, variant, path)
    vagus_verdict = verdict(vagus_status)

    if haos_verdict == vagus_verdict do
      nil
    else
      %{
        variant: variant["addon"],
        path: path,
        haos: haos,
        vagus: vagus_verdict,
        status: vagus_status
      }
    end
  end

  defp verdict(status) when status in [401, 403], do: :denied
  defp verdict(_status), do: :permitted

  defp request(key, variant, path) do
    token = "matrix-#{variant["addon"]}-#{System.unique_integer([:positive])}"
    :ok = Registry.register(token, identity(key, variant))

    try do
      {path, query} = split_query(path)

      :get
      |> conn(path)
      |> Map.put(:query_string, query)
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
      |> Dispatcher.call(@opts)
      |> Map.fetch!(:status)
    rescue
      # A handler that raises has already told us what this test asks: the
      # credential got past the lattice. Handlers reach for backends this test
      # never sets up — the suite runs under `Mox.set_mox_global()` and another
      # sync test's expectations can be exhausted by the time this one runs — so
      # treating a raise as "permitted" makes the gate independent of every
      # backend, rather than of whichever ones happen to be stubbed today.
      #
      # It also fails safe: if authorization itself ever started raising instead
      # of answering 403, that path would read as permitted, diverge from a
      # fixture that says denied, and land in the `looser` bucket, which is
      # never suppressed.
      _error -> 500
    after
      Registry.unregister_slug(variant["addon"])
    end
  end

  defp split_query(path) do
    case String.split(path, "?", parts: 2) do
      [only] -> {only, ""}
      [p, q] -> {p, q}
    end
  end

  # The variant key is the permission set itself, so the identity is rebuilt
  # from it rather than from anything Vagus already believes.
  defp identity(key, variant) do
    fields =
      key
      |> String.split(",")
      |> Map.new(fn pair ->
        [k, v] = String.split(pair, "=", parts: 2)
        {k, v}
      end)

    %{
      slug: variant["addon"],
      services_role: %{},
      discovery: [],
      hassio_api: fields["hassio_api"] == "true",
      hassio_role: fields["role"],
      homeassistant_api: fields["homeassistant_api"] == "true",
      auth_api: fields["auth_api"] == "true"
    }
  end

  defp format(divergences) do
    divergences
    |> Enum.sort_by(&{&1.variant, &1.path})
    |> Enum.map_join("\n", fn d ->
      haos = "HAOS #{d.haos["status"]} #{d.haos["class"]}#{message(d.haos)}"

      "  #{String.pad_trailing(d.variant, 22)} #{String.pad_trailing(d.path, 34)} #{haos}  ->  Vagus #{d.status}"
    end)
  end

  defp message(%{"message" => message}), do: " (#{message})"
  defp message(_haos), do: ""
end
