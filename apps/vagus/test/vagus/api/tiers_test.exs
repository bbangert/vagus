defmodule Vagus.API.TiersTest do
  @moduledoc """
  The tier table, pinned.

  Routes are pinned by `test/fixtures/vagus-authz-table.json`: one row per
  route `Vagus.API.Router` registers, with the tier the table demands, the
  tier upstream's `security.py` demands, and how the two compare. The route
  list is read from the router's source (`Vagus.RouterRoutes`), because a
  hand-kept list went stale without anything failing: two routes were pinned
  by no entry. A route nobody graded now fails here instead of shipping.

  The fixture is a second transcription of the same contract, reviewed
  against upstream by hand; two transcriptions catch drift, one does not.
  `upstream_tier` is the first of upstream's checks the path matches, in
  `token_validation`'s order: `no_security_check`, `core_only`, `bypass`,
  then the lowest `role_access` role that admits it.
  """

  use ExUnit.Case, async: true

  alias Vagus.API.Tiers
  alias Vagus.RouterRoutes

  @fixture_path Path.expand("../../fixtures/vagus-authz-table.json", __DIR__)
  @external_resource @fixture_path
  @fixture @fixture_path |> File.read!() |> Jason.decode!() |> Map.fetch!("routes")

  # Who each requirement admits, written out rather than asked of
  # `Tiers.allows?/2`, so the comparison with upstream does not lean on the
  # lattice it is checking. `anonymous` is a caller with no token.
  @admits %{
    "anonymous" => ~w(anonymous none default backup homeassistant manager admin supervisor),
    "bypass" => ~w(none default backup homeassistant manager admin supervisor),
    "default" => ~w(default backup homeassistant manager admin supervisor),
    "backup" => ~w(backup manager admin supervisor),
    "homeassistant" => ~w(homeassistant manager admin supervisor),
    "manager" => ~w(manager admin supervisor),
    "admin" => ~w(admin supervisor),
    "supervisor" => ~w(supervisor)
  }

  @upstream_names %{"no_security_check" => "anonymous", "core_only" => "supervisor"}

  # Paths the router does not serve, whose tier still has to be right the day
  # a route for them lands.
  @unserved [
    # Upstream's empty alternative matches `""`, never `/`.
    {"/", :admin},
    {"/nonexistent", :admin},
    {"/os/datadisk/wipe", :admin},
    {"/addons/core_mqtt/sys_options", :supervisor},
    {"/addons/self/sys_options", :supervisor},
    {"/os/ssh/authorized_keys", :supervisor},
    {"/os/ssh/authorized_keys/extra", :manager},
    {"/os/ssh", :manager},
    {"/addons/reload", :manager}
  ]

  defp segments(path), do: path |> String.split("/", trim: true)

  defp admitted(name), do: MapSet.new(Map.fetch!(@admits, Map.get(@upstream_names, name, name)))

  defp compare(vagus, upstream) do
    cond do
      MapSet.equal?(vagus, upstream) -> "parity"
      MapSet.subset?(vagus, upstream) -> "stricter"
      true -> "looser"
    end
  end

  describe "the table against the router and upstream" do
    test "every route the router registers has a row, and no row is stale" do
      routed = RouterRoutes.instances()
      pinned = for row <- @fixture, do: {row["method"], row["route"], row["path"]}

      assert routed != []
      assert routed -- pinned == [], "routes with no fixture row"
      assert pinned -- routed == [], "fixture rows the router no longer registers"
      assert pinned == Enum.uniq(pinned)
    end

    test "every route demands the tier its row pins" do
      for row <- @fixture do
        actual = row["path"] |> segments() |> Tiers.required() |> Atom.to_string()

        assert actual == row["requirement"],
               "#{row["method"]} #{row["path"]} requires #{actual}, pinned as #{row["requirement"]}"

        assert row["predicates"] == %{}
      end
    end

    test "no route is looser than upstream, and every row says how it compares" do
      for row <- @fixture do
        computed = compare(admitted(row["requirement"]), admitted(row["upstream_tier"]))
        label = "#{row["method"]} #{row["path"]}"

        refute computed == "looser",
               "#{label}: #{row["requirement"]} admits a caller upstream's " <>
                 "#{row["upstream_tier"]} refuses"

        assert row["classification"] == computed, "#{label} is #{computed}"
      end
    end

    test "a stricter row says why" do
      for %{"classification" => "stricter"} = row <- @fixture do
        assert is_binary(row["reason"]) and row["reason"] != "",
               "#{row["method"]} #{row["path"]} is stricter than upstream with no reason"
      end
    end

    # No row constrains the method, so an anonymous row admits every method
    # on its path. That is only safe while nothing but a GET is routed there.
    test "only GET routes sit on an anonymous row" do
      anonymous = for %{"requirement" => "anonymous"} = row <- @fixture, do: row
      assert anonymous != []

      for row <- anonymous do
        assert row["method"] == "GET", "#{row["method"]} #{row["path"]} is served with no token"
      end
    end
  end

  describe "required/1" do
    test "paths the router does not serve are graded too" do
      for {path, expected} <- @unserved do
        actual = Tiers.required(segments(path))

        assert actual == expected,
               "#{path} requires #{inspect(actual)}, pinned as #{inspect(expected)}"
      end
    end

    test "the token-free paths are anonymous rows, for a real slug and nothing longer" do
      assert Tiers.required(["supervisor", "ping"]) == :anonymous

      for prefix <- [["addons"], ["store", "addons"]],
          slug <- ~w(core_mqtt self),
          kind <- ~w(icon logo) do
        assert Tiers.required(prefix ++ [slug, kind]) == :anonymous
      end

      # A segment that is not a slug must not ride the row: it falls through
      # to the family tier it had before the row existed.
      for slug <- ["bad!slug", "..", "."] do
        assert Tiers.required(["addons", slug, "icon"]) == :manager
        assert Tiers.required(["store", "addons", slug, "logo"]) == :manager
      end

      assert Tiers.required(["supervisor", "ping", "extra"]) == :manager
      assert Tiers.required(["addons", "core_mqtt", "icon", "extra"]) == :manager
      assert Tiers.required(["addons", "core_mqtt", "changelog"]) == :supervisor
    end

    test "an unlisted path is admin, so a route added tomorrow is closed" do
      assert Tiers.required(["brand", "new", "surface"]) == :admin
      assert Tiers.required(["v2", "apps"]) == :admin
    end

    # The regression test for the wildcard that shadowed four `:supervisor`
    # rows. `/addons/self/X` is the one place the table grants `:bypass` on a
    # pattern rather than a literal path, so it is the one place a too-broad
    # entry silently opens routes — and the handlers' own caller checks made
    # it invisible end-to-end. Asserted as an exact set, not a spot-check:
    # adding an entry to the allowlist has to be done here too.
    @self_bypassable ~w(info options logs stats start stop restart uninstall)

    test "exactly these /addons/self/X segments bypass — every other one is closed" do
      for segment <- @self_bypassable do
        assert Tiers.required(["addons", "self", segment]) == :bypass,
               "/addons/self/#{segment} lost its bypass"
      end

      # Every segment Vagus holds supervisor-only for a normal slug must hold
      # it for `self` as well.
      for segment <- ~w(install update security changelog documentation sys_options) do
        assert Tiers.required(["addons", "self", segment]) == :supervisor,
               "/addons/self/#{segment} graded below :supervisor"
      end

      # And anything nobody has thought about falls to the manager family,
      # never to :bypass. `rebuild`/`stdin`/`ports` are real upstream routes
      # Vagus does not serve yet; they are the concrete form of "added later".
      for segment <- ~w(rebuild stdin ports brand_new_route) do
        refute Tiers.required(["addons", "self", segment]) == :bypass,
               "/addons/self/#{segment} was open by default"

        assert Tiers.required(["addons", "self", segment]) == :manager
      end
    end

    test "`/.+/info` spans segments, matching upstream's `.+` rather than one" do
      assert Tiers.required(["network", "interface", "eth0", "info"]) == :default
      assert Tiers.required(["a", "b", "c", "d", "e", "info"]) == :default
      # `.+` needs at least one segment before `/info`.
      assert Tiers.required(["info"]) == :bypass
      # …and `info` must be the LAST segment.
      assert Tiers.required(["host", "info", "extra"]) == :manager
    end
  end

  # Upstream's `BLACKLIST` (security review finding, phase 8): refused for
  # every caller regardless of token or tier, checked before `required/1` is
  # even consulted. Now expressed as `Vagus.Core.Reserved`'s namespace
  # reservation rather than a list of paths — see that module for why.
  describe "blacklisted?/1" do
    test "the two upstream families are blacklisted, with or without a suffix" do
      assert Tiers.blacklisted?(["core", "api", "hassio"])
      assert Tiers.blacklisted?(["core", "api", "hassio", "anything"])
      assert Tiers.blacklisted?(["core", "api", "hassio", "deeply", "nested"])
      assert Tiers.blacklisted?(["homeassistant", "api", "hassio"])
      assert Tiers.blacklisted?(["homeassistant", "api", "hassio", "x"])
    end

    # The upstream account-takeover: `hassio_auth` is a sibling VIEW of
    # `hassio`, not a path under it, so a deny that matched `hassio/` let an
    # add-on reset any HA user's password — owner included — through the
    # proxy, as the Supervisor. Whole-namespace matching is what closes it.
    test "the `hassio_`-prefixed views are blacklisted too, not just `hassio/`" do
      assert Tiers.blacklisted?(["core", "api", "hassio_auth"])
      assert Tiers.blacklisted?(["core", "api", "hassio_auth", "password_reset"])
      assert Tiers.blacklisted?(["homeassistant", "api", "hassio_auth"])
      assert Tiers.blacklisted?(["homeassistant", "api", "hassio_auth", "password_reset"])
      assert Tiers.blacklisted?(["core", "api", "hassio_push", "discovery", "uuid"])
      assert Tiers.blacklisted?(["core", "api", "hassio_ingress", "token", "path"])
    end

    # Deliberately wider than upstream's `hassio(?:/|_)`: the whole prefix is
    # reserved, so a view Core has not shipped yet is refused on the day it
    # ships rather than the day somebody notices.
    test "an unshipped `hassio`-prefixed view is blacklisted by the reservation alone" do
      assert Tiers.blacklisted?(["core", "api", "hassiofoo"])
      assert Tiers.blacklisted?(["core", "api", "hassio_not_invented_yet", "x"])
    end

    test "a near-miss is not blacklisted — the reservation starts at Core's view name" do
      refute Tiers.blacklisted?(["core", "api", "other"])
      refute Tiers.blacklisted?(["core", "apixhassio"])
      refute Tiers.blacklisted?(["core", "api"])
      refute Tiers.blacklisted?(["homeassistant", "api", "other"])
      refute Tiers.blacklisted?([])

      # `hassio` is only reserved as Core's view name, i.e. straight after
      # `api` — deeper down it is an ordinary path segment on an ordinary
      # Core endpoint, and refusing those would break real add-ons.
      refute Tiers.blacklisted?(["core", "api", "states", "sensor.hassio_cpu"])
      refute Tiers.blacklisted?(["core", "api", "config", "hassio_auth"])

      # Not a proxy family: `/supervisor/...` and friends never reach Core.
      refute Tiers.blacklisted?(["supervisor", "api", "hassio_auth"])
    end
  end

  describe "caller_tier/1" do
    test "Core's token is the supervisor tier" do
      assert Tiers.caller_tier(:supervisor) == :supervisor
    end

    test "an add-on's declared role becomes its tier" do
      for role <- ~w(default homeassistant backup manager admin) do
        assert Tiers.caller_tier({:addon, identity(true, role)}) ==
                 String.to_existing_atom(role)
      end
    end

    test "hassio_api: false is :none whatever the declared role" do
      for role <- ~w(default homeassistant backup manager admin) do
        assert Tiers.caller_tier({:addon, identity(false, role)}) == :none
      end
    end

    test "an unknown role falls back to :default, never upward" do
      assert Tiers.caller_tier({:addon, identity(true, "superuser")}) == :default
    end

    test "an identity missing both fields grades closed" do
      assert Tiers.caller_tier({:addon, %{slug: "legacy"}}) == :none
    end

    defp identity(hassio_api, hassio_role) do
      %{
        slug: "probe",
        services_role: %{},
        auth_api: false,
        discovery: [],
        hassio_api: hassio_api,
        hassio_role: hassio_role
      }
    end
  end

  # Audit A8. These are the ONLY tests that can pin this rule: its false
  # branch is unreachable through `GET /addons/{slug}/info`, because
  # `resolve_info_slug/2` refuses an add-on any slug but its own long before
  # the redaction is consulted. Deleting the redaction outright broke no
  # end-to-end test — which is why the rule was moved here and given explicit
  # arguments instead of reading `conn.assigns` in the router.
  describe "expose_options?/3" do
    defp addon(slug, hassio_role \\ "default") do
      {:addon, identity_for(slug, hassio_role)}
    end

    defp identity_for(slug, hassio_role) do
      %{
        slug: slug,
        services_role: %{},
        auth_api: false,
        discovery: [],
        hassio_api: true,
        hassio_role: hassio_role
      }
    end

    test "Core and other non-add-on internals always see options" do
      assert Tiers.expose_options?(:supervisor, :supervisor, "core_mosquitto")
    end

    test "an add-on sees its OWN options whatever its tier" do
      for tier <- ~w(none default homeassistant backup manager admin)a do
        assert Tiers.expose_options?(addon("core_mosquitto"), tier, "core_mosquitto"),
               "#{tier} was denied its own options"
      end
    end

    test "manager and admin see another add-on's options; nothing below does" do
      other = addon("core_nosy")

      assert Tiers.expose_options?(other, :manager, "core_mosquitto")
      assert Tiers.expose_options?(other, :admin, "core_mosquitto")

      for tier <- ~w(none default homeassistant backup)a do
        refute Tiers.expose_options?(other, tier, "core_mosquitto"),
               "#{tier} saw another add-on's options"
      end
    end

    test "the match is on the resolved slug, not a prefix or a near-miss" do
      # `core_mosquitto2` must not inherit `core_mosquitto`'s options.
      refute Tiers.expose_options?(addon("core_mosquitto2"), :default, "core_mosquitto")
      refute Tiers.expose_options?(addon("core_mosquitto"), :default, "core_mosquitto2")
      refute Tiers.expose_options?(addon(""), :default, "core_mosquitto")
    end
  end

  describe "allows?/2 — the lattice" do
    # The full matrix, written out rather than computed, so a change to the
    # ordering has to be made here too.
    @matrix %{
      supervisor: ~w(anonymous bypass default homeassistant backup manager admin supervisor)a,
      admin: ~w(anonymous bypass default homeassistant backup manager admin)a,
      manager: ~w(anonymous bypass default homeassistant backup manager)a,
      backup: ~w(anonymous bypass default backup)a,
      homeassistant: ~w(anonymous bypass default homeassistant)a,
      default: ~w(anonymous bypass default)a,
      none: ~w(anonymous bypass)a
    }

    @all_requirements ~w(anonymous bypass default homeassistant backup manager admin supervisor)a

    test "each tier reaches exactly the requirements it should" do
      for {tier, allowed} <- @matrix, requirement <- @all_requirements do
        expected = requirement in allowed
        actual = Tiers.allows?(tier, requirement)

        assert actual == expected,
               "#{tier} → #{requirement}: got #{actual}, expected #{expected}"
      end
    end

    test "backup and homeassistant are siblings, not a line" do
      refute Tiers.allows?(:backup, :homeassistant)
      refute Tiers.allows?(:homeassistant, :backup)
    end

    test "only the supervisor satisfies a supervisor-only route" do
      for tier <- Map.keys(@matrix), tier != :supervisor do
        refute Tiers.allows?(tier, :supervisor), "#{tier} reached a supervisor-only route"
      end
    end

    test "every tier satisfies bypass, including :none" do
      for tier <- Map.keys(@matrix) do
        assert Tiers.allows?(tier, :bypass)
      end
    end
  end
end
