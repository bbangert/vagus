defmodule Vagus.API.TiersTest do
  @moduledoc """
  The tier table, pinned.

  `@routes` below is transcribed **independently** of `Vagus.API.Tiers`'
  `@table` — from upstream `supervisor/api/middleware/security.py`'s regex
  alternatives plus the deliberate supervisor-only overrides recorded in the
  2026-07-29 audit — exactly the way `Vagus.API.RouterTest` pins field lists
  from the contract rather than from the model modules. Two transcriptions of
  the same contract catch drift; one does not.

  This is the file that would have caught A2 (26 routes admin-tier to any
  installed add-on): every route the router registers appears here with the
  tier it demands, so a route that quietly loses its guard fails a test
  instead of shipping.
  """

  use ExUnit.Case, async: true

  alias Vagus.API.Tiers

  # {path, required tier}. Every route `Vagus.API.Router` registers, in router
  # order, plus the `self`/negative-lookahead variants the router serves
  # through a `:slug` segment and the two upstream paths Vagus does not serve
  # (`sys_options`, `datadisk/wipe`) whose entries keep the catch-all honest.
  @routes [
    # -- Main coordinator + one-time setup GETs -------------------------------
    {"/info", :bypass},
    {"/supervisor/info", :default},
    {"/core/info", :default},
    {"/os/info", :default},
    {"/os/datadisk/list", :supervisor},
    {"/host/info", :default},
    {"/host/disks/default/usage", :supervisor},
    {"/hardware/info", :default},
    {"/network/info", :default},
    {"/network/interface/eth0/info", :default},
    {"/network/interface/eth0/accesspoints", :manager},
    {"/network/interface/eth0/update", :manager},
    {"/host/reboot", :manager},
    {"/host/shutdown", :manager},

    # -- Store ----------------------------------------------------------------
    {"/store", :manager},
    {"/store/addons", :manager},
    {"/store/addons/core_mqtt", :manager},
    # The icon/logo GETs never consult the table — `Vagus.API.Auth` serves
    # them with no token at all — but a non-GET on the same path does, and
    # manager is where upstream's `role_access` puts it.
    {"/store/addons/core_mqtt/icon", :manager},
    {"/store/addons/core_mqtt/logo", :manager},
    {"/addons/core_mqtt/icon", :manager},
    {"/addons/core_mqtt/logo", :manager},
    {"/store/addons/core_mqtt/changelog", :supervisor},
    {"/store/addons/core_mqtt/documentation", :supervisor},
    {"/addons/core_mqtt/changelog", :supervisor},
    {"/addons/core_mqtt/documentation", :supervisor},
    {"/mounts", :manager},
    {"/resolution/info", :default},
    {"/jobs/info", :default},

    # -- Add-ons --------------------------------------------------------------
    {"/addons", :manager},
    {"/addons/core_mqtt/info", :default},
    {"/addons/self/info", :bypass},
    {"/addons/core_mqtt/options/config", :manager},
    {"/addons/self/options/config", :bypass},
    {"/store/addons/core_mqtt/install", :supervisor},
    {"/addons/core_mqtt/install", :supervisor},
    {"/store/addons/core_mqtt/update", :supervisor},
    {"/store/addons/core_mqtt/update/1.2.3", :supervisor},
    {"/addons/core_mqtt/update", :supervisor},
    # `(?!security|update)` — the two segments upstream carves OUT of the
    # `self` bypass. Vagus keeps both supervisor-only.
    {"/addons/self/update", :supervisor},
    {"/addons/self/security", :supervisor},
    # …and the segments Vagus holds at `:supervisor` for ANY slug must keep
    # that tier when the slug is the literal `self` too. An earlier revision
    # wildcarded the third segment and silently graded all four `:bypass`.
    {"/addons/self/install", :supervisor},
    {"/addons/self/changelog", :supervisor},
    {"/addons/self/documentation", :supervisor},
    {"/addons/self/sys_options", :supervisor},
    {"/addons/core_mqtt/security", :admin},
    {"/addons/core_mqtt/start", :supervisor},
    {"/addons/core_mqtt/stop", :supervisor},
    {"/addons/core_mqtt/restart", :supervisor},
    {"/addons/core_mqtt/uninstall", :supervisor},
    {"/addons/core_mqtt/options", :supervisor},
    # `/addons/self/(?!security|update)[^/]+` — an add-on manages itself.
    {"/addons/self/start", :bypass},
    {"/addons/self/stop", :bypass},
    {"/addons/self/restart", :bypass},
    {"/addons/self/uninstall", :bypass},
    {"/addons/self/options", :bypass},
    # …but `[^/]+` is ONE segment, so the two-segment forms are not bypassed.
    {"/addons/core_mqtt/options/validate", :supervisor},
    {"/addons/self/options/validate", :supervisor},
    # `core_only` — Vagus serves no such route; the entry stops the catch-all
    # from handing it to an admin-role add-on if one is ever added.
    {"/addons/core_mqtt/sys_options", :supervisor},

    # -- Stats ----------------------------------------------------------------
    {"/core/stats", :homeassistant},
    {"/supervisor/stats", :manager},
    {"/addons/core_mqtt/stats", :manager},
    {"/addons/self/stats", :bypass},

    # -- Logs -----------------------------------------------------------------
    {"/addons/core_mqtt/logs", :manager},
    {"/addons/self/logs", :bypass},
    # Audit F8: two segments, so outside `[^/]+` — manager, not bypass.
    {"/addons/self/logs/latest", :manager},
    {"/addons/self/logs/follow", :manager},
    {"/addons/self/logs/boots/3", :manager},
    {"/addons/core_mqtt/logs/latest", :manager},
    {"/core/logs", :homeassistant},
    {"/core/logs/latest", :homeassistant},
    {"/core/logs/follow", :homeassistant},
    {"/core/logs/boots/3", :homeassistant},
    {"/core/logs/boots/3/follow", :homeassistant},
    {"/supervisor/logs", :manager},
    {"/supervisor/logs/latest", :manager},
    {"/supervisor/logs/follow", :manager},
    {"/supervisor/logs/boots/3", :manager},
    {"/supervisor/logs/boots/3/follow", :manager},
    {"/host/logs", :manager},
    {"/host/logs/latest", :manager},
    {"/host/logs/follow", :manager},
    {"/host/logs/boots", :manager},
    {"/host/logs/boots/3", :manager},
    {"/host/logs/boots/3/follow", :manager},
    {"/host/logs/identifiers", :manager},
    {"/homeassistant/logs", :homeassistant},
    {"/homeassistant/logs/latest", :homeassistant},
    {"/homeassistant/logs/follow", :homeassistant},
    {"/homeassistant/logs/boots/3", :homeassistant},
    {"/homeassistant/logs/boots/3/follow", :homeassistant},
    {"/audio/logs", :manager},
    {"/audio/logs/latest", :manager},
    {"/audio/logs/follow", :manager},
    {"/audio/logs/boots/3", :manager},
    {"/audio/logs/boots/3/follow", :manager},
    {"/dns/logs", :manager},
    {"/dns/logs/latest", :manager},
    {"/dns/logs/follow", :manager},
    {"/dns/logs/boots/3", :manager},
    {"/dns/logs/boots/3/follow", :manager},
    {"/multicast/logs", :manager},
    {"/multicast/logs/latest", :manager},
    {"/multicast/logs/follow", :manager},
    {"/multicast/logs/boots/3", :manager},
    {"/multicast/logs/boots/3/follow", :manager},
    {"/available_updates", :manager},

    # -- Ingress --------------------------------------------------------------
    # No role below `role_access[admin]` lists an `/ingress/…` alternative
    # (audit A5). The per-request proxy path `/ingress/{token}/…` never
    # reaches this table — `Vagus.API.Dispatcher` routes it to the proxy.
    {"/ingress/panels", :admin},
    {"/ingress/session", :admin},
    {"/ingress/validate_session", :admin},

    # -- Discovery ------------------------------------------------------------
    {"/discovery", :bypass},
    {"/discovery/8ced93a7", :bypass},

    # -- Backups (audit A4: ROLE_BACKUP, not supervisor-only) -----------------
    {"/backups", :backup},
    # `/.+/info` is checked before `/backups.*`, upstream and here.
    {"/backups/info", :default},
    {"/backups/abc123/info", :default},
    {"/backups/new/partial", :backup},
    {"/backups/new/upload", :backup},
    {"/backups/abc123/restore/partial", :backup},
    {"/backups/abc123/download", :backup},
    {"/backups/abc123", :backup},
    {"/backups/reload", :backup},

    # -- Services / auth ------------------------------------------------------
    {"/services", :bypass},
    {"/services/mqtt", :bypass},
    {"/auth", :bypass},
    # NOT part of the `/auth` bypass — the alternative is anchored (audit A6).
    {"/auth/cache", :manager},

    # -- Entry setup / Core lifecycle -----------------------------------------
    {"/supervisor/ping", :bypass},
    {"/core/options", :homeassistant},
    {"/homeassistant/options", :homeassistant},
    {"/core/start", :supervisor},
    {"/core/stop", :supervisor},
    {"/core/restart", :supervisor},
    {"/core/rebuild", :supervisor},
    {"/core/check", :supervisor},
    {"/core/update", :supervisor},
    {"/homeassistant/start", :supervisor},
    {"/homeassistant/stop", :supervisor},
    {"/homeassistant/restart", :supervisor},
    {"/homeassistant/rebuild", :supervisor},
    {"/homeassistant/check", :supervisor},
    {"/homeassistant/update", :supervisor},

    # -- Supervisor self ------------------------------------------------------
    {"/supervisor/options", :manager},
    {"/supervisor/reload", :manager},
    {"/refresh_updates", :manager},
    # V1's manager list has `/refresh_updates` but NOT `/reload_updates`
    # (only the V2 list does), so this one is admin.
    {"/reload_updates", :admin},
    {"/store/reload", :manager},
    {"/supervisor/restart", :manager},
    {"/supervisor/update", :manager},

    # -- Not served -----------------------------------------------------------
    {"/os/datadisk/wipe", :admin},
    {"/nonexistent", :admin},
    {"/", :default}
  ]

  defp segments(path), do: path |> String.split("/", trim: true)

  describe "required/1" do
    test "every registered route demands its pinned tier" do
      for {path, expected} <- @routes do
        actual = Tiers.required(segments(path))

        assert actual == expected,
               "#{path} requires #{inspect(actual)}, pinned as #{inspect(expected)}"
      end
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
      supervisor: ~w(bypass default homeassistant backup manager admin supervisor)a,
      admin: ~w(bypass default homeassistant backup manager admin)a,
      manager: ~w(bypass default homeassistant backup manager)a,
      backup: ~w(bypass default backup)a,
      homeassistant: ~w(bypass default homeassistant)a,
      default: ~w(bypass default)a,
      none: ~w(bypass)a
    }

    @all_requirements ~w(bypass default homeassistant backup manager admin supervisor)a

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
