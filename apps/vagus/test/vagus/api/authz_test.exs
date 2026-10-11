defmodule Vagus.API.AuthzTest do
  @moduledoc """
  The evaluator: that the table and the lattice are applied, in the right
  order, to every kind of principal.

  `Vagus.API.TiersTest` pins what each path demands. This file pins what a
  caller gets, so a decision that stops consulting the table fails here even
  with the table intact.
  """

  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 2]

  alias Vagus.API.{Auth, Authz}
  alias Vagus.RouterRoutes

  @fixture_path Path.expand("../../fixtures/vagus-authz-table.json", __DIR__)
  @external_resource @fixture_path
  @fixture @fixture_path |> File.read!() |> Jason.decode!() |> Map.fetch!("routes")

  # One served path per requirement.
  @paths %{
    anonymous: "/supervisor/ping",
    bypass: "/info",
    default: "/supervisor/info",
    homeassistant: "/core/stats",
    backup: "/backups",
    manager: "/store",
    admin: "/ingress/panels",
    supervisor: "/core/restart"
  }

  # Written out, not computed: a change to the lattice has to be made here too.
  @reaches %{
    supervisor: ~w(anonymous bypass default homeassistant backup manager admin supervisor)a,
    admin: ~w(anonymous bypass default homeassistant backup manager admin)a,
    manager: ~w(anonymous bypass default homeassistant backup manager)a,
    backup: ~w(anonymous bypass default backup)a,
    homeassistant: ~w(anonymous bypass default homeassistant)a,
    default: ~w(anonymous bypass default)a,
    none: ~w(anonymous bypass)a,
    anonymous: ~w(anonymous)a
  }

  defp principal(:supervisor), do: :supervisor
  defp principal(:anonymous), do: :anonymous
  # `:none` declares the admin role on purpose: without `hassio_api` it must
  # grade as nothing.
  defp principal(:none), do: {:addon, identity(false, "admin")}
  defp principal(role), do: {:addon, identity(true, Atom.to_string(role))}

  defp identity(hassio_api, hassio_role) do
    %{slug: "probe", hassio_api: hassio_api, hassio_role: hassio_role}
  end

  defp segments(path), do: String.split(path, "/", trim: true)

  defp decode(segments), do: Enum.map(segments, &URI.decode/1)

  defp ctx(path), do: %{leg: :supervisor_api, decoded_segments: path |> segments() |> decode()}

  defp authorize(who, path, method \\ "GET"),
    do:
      Authz.authorize(principal(who), {:rest, :supervisor_api, method, segments(path)}, ctx(path))

  defp refusal(:anonymous), do: {:error, :unauthenticated}
  defp refusal(_who), do: {:error, :forbidden}

  # What a fixture row's predicates admit among these principals, written out
  # rather than asked of `Authz`. Every app here is `probe` and holds no grant.
  defp held?(predicates, who, path) do
    Enum.all?(predicates, fn
      {"subject", "self"} -> who == :supervisor or Enum.at(segments(path), 1) in ~w(self probe)
      {"caller", "supervisor"} -> who == :supervisor
      {"requires", "auth_api"} -> false
      {"requires", ["services_role", "any"]} -> who == :supervisor
    end)
  end

  describe "the lattice" do
    test "each principal reaches exactly the requirements it should" do
      for {who, reaches} <- @reaches, {requirement, path} <- @paths do
        expected = if requirement in reaches, do: :ok, else: refusal(who)

        assert authorize(who, path) == expected,
               "#{who} on #{path} (#{requirement}): expected #{inspect(expected)}"
      end
    end

    test "every route decides as its pinned row says, for every principal" do
      for row <- @fixture, {who, reaches} <- @reaches do
        requirement = String.to_existing_atom(row["requirement"])

        expected =
          if requirement in reaches and held?(row["predicates"], who, row["path"]),
            do: :ok,
            else: refusal(who)

        assert authorize(who, row["path"], row["method"]) == expected,
               "#{who} on #{row["method"]} #{row["path"]}: expected #{inspect(expected)}"
      end
    end

    # `auth_api` is a grant only an app holds, so its row is the one Core
    # does not pass.
    test "the supervisor satisfies every row but the auth API's, and the fallback" do
      refused =
        for {method, _route, path} <- RouterRoutes.instances(),
            authorize(:supervisor, path, method) != :ok,
            do: {method, path}

      assert refused == [{"GET", "/auth"}, {"POST", "/auth"}]
      assert authorize(:supervisor, "/auth") == {:error, :forbidden}
      assert authorize(:supervisor, "/no/such/route") == :ok
    end

    test "an unknown path falls to admin" do
      for path <- ["/no/such/route", "/", "/v2/apps"] do
        assert authorize(:admin, path) == :ok
        assert authorize(:manager, path) == {:error, :forbidden}
        assert authorize(:none, path) == {:error, :forbidden}
        assert authorize(:anonymous, path) == {:error, :unauthenticated}
      end
    end

    test "the method changes nothing" do
      for {who, _reaches} <- @reaches, {_requirement, path} <- @paths do
        decisions = for method <- ~w(GET POST DELETE PUT BREW), do: authorize(who, path, method)
        assert decisions |> Enum.uniq() |> length() == 1, "#{who} on #{path}"
      end
    end

    test "an identity that declares nothing grades closed" do
      bare = {:addon, %{slug: "legacy"}}
      action = fn path -> {:rest, :supervisor_api, "GET", segments(path)} end

      assert Authz.authorize(bare, action.("/info"), ctx("/info")) == :ok

      assert Authz.authorize(bare, action.("/supervisor/info"), ctx("/supervisor/info")) ==
               {:error, :forbidden}
    end
  end

  describe "the blacklist" do
    @blacklisted ["/core/api/hassio/x", "/homeassistant/api/hassio", "/core/api/hassio_auth"]

    # `/core/api/hassio/x` would otherwise grade `:homeassistant`, which the
    # supervisor, admin, manager and homeassistant principals all satisfy.
    test "runs before the lattice: no principal satisfies it, the supervisor included" do
      for path <- @blacklisted, {who, _reaches} <- @reaches, method <- ~w(GET POST) do
        assert authorize(who, path, method) == {:error, :blacklisted},
               "#{who} was not refused #{path} as blacklisted"
      end
    end

    test "a near miss is graded normally" do
      assert authorize(:supervisor, "/core/api/other") == :ok
      assert authorize(:homeassistant, "/core/api/other") == :ok
      assert authorize(:default, "/core/api/other") == {:error, :forbidden}
      assert authorize(:anonymous, "/core/api/other") == {:error, :unauthenticated}
    end
  end

  describe "the anonymous principal" do
    test "satisfies the anonymous rows and no other" do
      for path <- ~w(/supervisor/ping /addons/core_mqtt/icon /addons/self/logo
                     /store/addons/core_mqtt/icon /store/addons/core_mqtt/logo) do
        assert authorize(:anonymous, path) == :ok, path
      end

      for {method, _route, path} <- RouterRoutes.instances() do
        row = Enum.find(@fixture, &(&1["method"] == method and &1["path"] == path))

        unless row["requirement"] == "anonymous" do
          assert authorize(:anonymous, path, method) == {:error, :unauthenticated},
                 "no token reached #{method} #{path}"
        end
      end
    end

    test "is not admitted by the bypass rows any app token satisfies" do
      for path <- ~w(/info /services /discovery /addons/self/info) do
        assert authorize(:none, path) == :ok
        assert authorize(:anonymous, path) == {:error, :unauthenticated}
      end

      # `/auth` is a bypass row too, with a grant on top.
      action = {:rest, :supervisor_api, "GET", ["auth"]}
      holder = {:addon, Map.put(identity(false, "default"), :auth_api, true)}

      assert Authz.authorize(holder, action, ctx("/auth")) == :ok
      assert authorize(:anonymous, "/auth") == {:error, :unauthenticated}
    end

    test "is refused a segment that is not a slug" do
      for path <- ["/addons/bad!slug/icon", "/addons/../icon", "/store/addons/bad!slug/logo"] do
        assert authorize(:anonymous, path) == {:error, :unauthenticated}
        assert authorize(:default, path) == {:error, :forbidden}
      end
    end

    # The two halves of the token-free decision have to name the same paths,
    # or one of them is dead.
    test "Auth serves a GET token-free exactly where the table has an anonymous row" do
      paths =
        Enum.map(RouterRoutes.instances(), &elem(&1, 2)) ++
          ~w(/ /supervisor/ping/extra /addons/bad!slug/icon /addons/../logo /nonexistent
             /addons/core_mqtt/icon/extra /store/addons/self/logo /core/api/hassio/x)

      for path <- Enum.uniq(paths) do
        assert Auth.unauthenticated?(conn(:get, path)) == (authorize(:anonymous, path) == :ok),
               "Auth and the table disagree about #{path}"
      end
    end
  end

  describe "legs with no rows yet" do
    test "raise rather than answer" do
      for principal <- [:supervisor, :anonymous, principal(:admin)],
          action <- [
            {:rest, :core_api, "GET", ["states"]},
            {:ws, :core_api, "call_service", %{}},
            {:rest, :ingress, "GET", ["x"]}
          ] do
        assert_raise FunctionClauseError, fn ->
          Authz.authorize(principal, action, %{leg: :core_api, decoded_segments: nil})
        end
      end
    end

    test "a principal that is none of the three raises too" do
      action = {:rest, :supervisor_api, "GET", ["store"]}

      for principal <- [nil, :core, {:addon, nil}, "supervisor"] do
        assert_raise FunctionClauseError, fn ->
          Authz.authorize(principal, action, ctx("/store"))
        end
      end
    end

    test "a ctx for another leg, or with no decoded segments, has no clause" do
      action = {:rest, :supervisor_api, "GET", ["info"]}

      for ctx <- [
            %{leg: :core_api, decoded_segments: ["info"]},
            %{leg: :supervisor_api, decoded_segments: nil},
            %{leg: :supervisor_api},
            %{decoded_segments: ["info"]}
          ] do
        assert_raise FunctionClauseError, fn -> Authz.authorize(:supervisor, action, ctx) end
      end
    end
  end

  # The router matches percent-decoded segments, so a path has two spellings
  # and the stricter grade of the two is the decision.
  describe "an encoded spelling" do
    test "is held to the row its decoded form matches" do
      assert authorize(:homeassistant, "/core/%72estart", "POST") == {:error, :forbidden}
      assert authorize(:admin, "/c%6Fre/restart", "POST") == {:error, :forbidden}
      assert authorize(:manager, "/addons/core_ssh/%73ecurity", "POST") == {:error, :forbidden}
      assert authorize(:admin, "/addons/%73elf/security", "POST") == {:error, :forbidden}
      assert authorize(:manager, "/os/datadisk/%77ipe", "POST") == {:error, :forbidden}
      assert authorize(:supervisor, "/core/%72estart", "POST") == :ok
    end

    test "is held to the row its raw form matches too" do
      # Decoded, these are bypass and anonymous rows; raw, they match no row.
      assert authorize(:none, "/%69nfo") == {:error, :forbidden}
      assert authorize(:manager, "/%69nfo") == {:error, :forbidden}
      assert authorize(:admin, "/%69nfo") == :ok
      assert authorize(:anonymous, "/supervisor/%70ing") == {:error, :unauthenticated}
      assert authorize(:anonymous, "/addons/core_mqtt/%69con") == {:error, :unauthenticated}
    end

    test "of a blacklisted path is blacklisted, for every principal" do
      for path <- [
            "/core/api/%68assio/x",
            "/homeassistant/%61pi/hassio_auth",
            "/c%6Fre/api/hassio"
          ],
          {who, _reaches} <- @reaches do
        assert authorize(who, path) == {:error, :blacklisted}, "#{who} on #{path}"
      end
    end

    test "decodes once, and leaves what is not an escape alone" do
      # None of these is the supervisor-only `/core/restart` to the router
      # either: each grades as the `/core/.+` family it literally is.
      for path <- ["/core/%2572estart", "/core/%zzrestart", "/core/re+start", "/core/restart%"] do
        assert authorize(:homeassistant, path, "POST") == :ok, path
        assert authorize(:default, path, "POST") == {:error, :forbidden}, path
      end

      # An encoded slash stays inside its segment, so this is one unknown segment.
      assert authorize(:manager, "/core%2Frestart", "POST") == {:error, :forbidden}
      assert authorize(:admin, "/core%2Frestart", "POST") == :ok
    end
  end

  # Grants the lattice cannot express. Each is read off the principal and the
  # action, after the lattice, and a caller has to hold both.
  describe "predicates" do
    defp app(slug, grants \\ %{}) do
      {:addon, Map.merge(%{slug: slug, hassio_api: true, hassio_role: "admin"}, grants)}
    end

    defp decide(principal, path, method \\ "GET"),
      do: Authz.authorize(principal, {:rest, :supervisor_api, method, segments(path)}, ctx(path))

    @subject_rows ~w(info stats logs logs/latest logs/follow logs/boots/0 logs/boots/0/follow
                     options/config)

    test "subject: an app reaches its own slug and `self`, never another app's" do
      for tail <- @subject_rows do
        assert decide(app("mine"), "/addons/mine/#{tail}") == :ok, tail
        assert decide(app("mine"), "/addons/self/#{tail}") == :ok, tail
        assert decide(app("mine"), "/addons/theirs/#{tail}") == {:error, :forbidden}, tail
        # A prefix or a near miss is another app.
        assert decide(app("mine"), "/addons/mine2/#{tail}") == {:error, :forbidden}, tail
        assert decide(app("mine"), "/addons/min/#{tail}") == {:error, :forbidden}, tail
        assert decide(app("mine"), "/addons/SELF/#{tail}") == {:error, :forbidden}, tail
        assert decide(:supervisor, "/addons/theirs/#{tail}") == :ok, tail
      end
    end

    test "subject: an identity with no slug is nobody's own" do
      bare = {:addon, %{hassio_api: true, hassio_role: "admin"}}

      assert decide(bare, "/addons/theirs/info") == {:error, :forbidden}
      assert decide(bare, "/addons/nil/stats") == {:error, :forbidden}
      assert decide(app(nil), "/addons/nil/stats") == {:error, :forbidden}
      assert decide(app(nil), "/addons/self/logs/latest") == {:error, :forbidden}
    end

    test "subject: the lattice still has to be satisfied first" do
      # Its own stats, but the row wants manager.
      assert decide(app("mine", %{hassio_role: "default"}), "/addons/mine/stats") ==
               {:error, :forbidden}

      assert decide(app("mine", %{hassio_api: false}), "/addons/mine/info") ==
               {:error, :forbidden}

      assert decide(app("mine", %{hassio_role: "default"}), "/addons/mine/info") == :ok
    end

    test "the reserved panel slug's info is Core's alone, even for an app so named" do
      assert Vagus.API.AdminPanel.slug() == "vagus"
      assert decide(:supervisor, "/addons/vagus/info") == :ok
      assert decide(app("mine"), "/addons/vagus/info") == {:error, :forbidden}
      assert decide(app("vagus"), "/addons/vagus/info") == {:error, :forbidden}
      # Reserved on info only: the other rows resolve it like any slug.
      assert decide(app("vagus"), "/addons/vagus/stats") == :ok
      assert decide(app("vagus"), "/addons/self/info") == :ok
    end

    test "caller: only Core sets an app's protection or opens an ingress session" do
      for path <- ~w(/addons/mine/security /addons/theirs/security /ingress/session
                     /ingress/validate_session) do
        assert decide(:supervisor, path, "POST") == :ok, path
        assert decide(app("mine"), path, "POST") == {:error, :forbidden}, path
      end

      # The lattice refuses a manager before the predicate is reached.
      assert decide(app("mine", %{hassio_role: "manager"}), "/ingress/session", "POST") ==
               {:error, :forbidden}
    end

    test "requires auth_api: the flag, on an app, whatever its role" do
      assert decide(app("mine", %{auth_api: true}), "/auth", "POST") == :ok

      assert decide(app("mine", %{auth_api: true, hassio_api: false}), "/auth") == :ok

      for grants <- [%{}, %{auth_api: false}, %{auth_api: nil}, %{auth_api: "true"}] do
        assert decide(app("mine", grants), "/auth") == {:error, :forbidden}, inspect(grants)
      end

      # Core is not an app and holds no such grant.
      assert decide(:supervisor, "/auth") == {:error, :forbidden}
      # A different row, with no predicate.
      assert decide(app("mine"), "/auth/cache", "DELETE") == :ok
    end

    test "requires a services_role: any role for that service, and Core" do
      for role <- ~w(provide want need) do
        holder = app("mine", %{hassio_role: "default", services_role: %{"mqtt" => role}})
        assert decide(holder, "/services/mqtt") == :ok, role
        assert decide(holder, "/services/mysql") == {:error, :forbidden}, role
      end

      no_api = app("mine", %{hassio_api: false, services_role: %{"mqtt" => "want"}})
      assert decide(no_api, "/services/mqtt") == :ok

      for grants <- [%{}, %{services_role: %{}}, %{services_role: nil}] do
        manager = app("mine", Map.put(grants, :hassio_role, "manager"))
        assert decide(manager, "/services/mqtt") == {:error, :forbidden}, inspect(grants)
      end

      assert decide(:supervisor, "/services/mqtt") == :ok
      # The list, and anything deeper, has no service to hold a role for.
      assert decide(app("mine"), "/services") == :ok
      assert decide(app("mine"), "/services/mqtt/extra") == :ok
    end

    # Ownership of a message and the service in a body are not in the
    # principal or the action, so these rows stay the handler's.
    test "the discovery rows decide nothing the lattice does not" do
      for principal <- [:supervisor, app("mine"), app("mine", %{hassio_api: false})],
          {method, path} <- [
            {"GET", "/discovery"},
            {"POST", "/discovery"},
            {"GET", "/discovery/8ced93a7"},
            {"DELETE", "/discovery/8ced93a7"}
          ] do
        assert decide(principal, path, method) == :ok, "#{method} #{path}"
      end
    end

    test "the method changes no predicate's decision" do
      principals = [
        :supervisor,
        app("mine"),
        app("mine", %{auth_api: true, services_role: %{"mqtt" => "want"}})
      ]

      paths = ~w(/addons/mine/info /addons/theirs/stats /addons/vagus/info /addons/mine/security
                 /ingress/session /auth /services/mqtt /services/mysql /discovery)

      for principal <- principals, path <- paths do
        decisions =
          for method <- ~w(GET POST DELETE PUT BREW), do: decide(principal, path, method)

        assert decisions |> Enum.uniq() |> length() == 1, "#{inspect(principal)} on #{path}"
      end
    end

    # The rows are chosen under both spellings; the subject is the decoded
    # segment, which is the one the handler is given.
    test "an encoded spelling is judged on the subject the router will read" do
      mine = app("mine", %{auth_api: true, services_role: %{"mqtt" => "want"}})

      assert decide(mine, "/addons/%6Dine/info") == :ok
      assert decide(mine, "/addons/%73elf/info") == :ok
      assert decide(mine, "/addons/%6Dine/stats") == :ok
      assert decide(mine, "/addons/mine/%69nfo") == :ok
      assert decide(mine, "/services/%6Dqtt") == :ok
      assert decide(mine, "/%61uth") == :ok
      assert decide(:supervisor, "/addons/%74heirs/%69nfo") == :ok
      assert decide(:supervisor, "/addons/%76agus/info") == :ok

      # Raw, each of these matches a row with no predicate, or a looser one.
      assert decide(mine, "/addons/%74heirs/info") == {:error, :forbidden}
      assert decide(mine, "/addons/theirs/%69nfo") == {:error, :forbidden}
      assert decide(mine, "/addons/theirs/%73tats") == {:error, :forbidden}
      assert decide(mine, "/addons/theirs/logs/%6Catest") == {:error, :forbidden}
      assert decide(mine, "/addons/mine/%73ecurity", "POST") == {:error, :forbidden}
      assert decide(mine, "/addons/%76agus/info") == {:error, :forbidden}
      assert decide(mine, "/addons/vagus/%69nfo") == {:error, :forbidden}
      assert decide(mine, "/ingress/%73ession", "POST") == {:error, :forbidden}
      assert decide(mine, "/services/%6Dysql") == {:error, :forbidden}
      assert decide(app("mine"), "/%61uth") == {:error, :forbidden}
      assert decide(app("mine"), "/services/mq%74t") == {:error, :forbidden}
      # Decoding happens once: this names nobody.
      assert decide(mine, "/addons/%2573elf/stats") == {:error, :forbidden}
    end

    test "a tier's refusal is answered as one, whichever spelling the tier refused" do
      default = app("mine", %{hassio_role: "default"})

      # Raw, no row: admin. Decoded, the auth row and its predicate.
      for method <- ~w(GET POST DELETE) do
        assert decide(default, "/%61uth", method) == {:error, :forbidden}
        assert answer(default, "/%61uth", method) == {403, "unauthorized"}
      end

      assert answer(app("mine"), "/%61uth") ==
               {403, "Caller is not allowed to access the auth API"}
    end

    test "no single-byte encoding of a predicate row is graded more leniently" do
      principals = [
        :supervisor,
        app("core_ssh"),
        app("other"),
        app("other", %{auth_api: true, services_role: %{"mqtt" => "provide"}}),
        app("core_ssh", %{hassio_role: "default"}),
        app("other", %{hassio_api: false})
      ]

      rows = for row <- @fixture, row["predicates"] != %{} or row["path"] =~ "vagus", do: row
      assert length(rows) >= 20

      for row <- rows,
          path <- [row["path"], String.replace(row["path"], "core_ssh", "vagus")],
          segs = segments(path),
          index <- 0..(length(segs) - 1),
          at <- 0..(byte_size(Enum.at(segs, index)) - 1),
          principal <- principals do
        <<head::binary-size(^at), byte, tail::binary>> = Enum.at(segs, index)

        encoded =
          "/" <>
            Enum.join(
              List.replace_at(segs, index, head <> "%" <> Base.encode16(<<byte>>) <> tail),
              "/"
            )

        if decide(principal, encoded, row["method"]) == :ok do
          assert decide(principal, path, row["method"]) == :ok,
                 "#{encoded} admits #{inspect(principal)}; #{path} does not"
        end
      end
    end
  end

  describe "answer/3" do
    defp answer(principal, path, method \\ "GET"),
      do: Authz.answer(principal, {:rest, :supervisor_api, method, segments(path)}, ctx(path))

    test "raises for a caller who was not refused as forbidden" do
      for {who, path} <- [
            {principal(:admin), "/store"},
            {:supervisor, "/core/restart"},
            {:anonymous, "/store"},
            {:supervisor, "/core/api/hassio/x"}
          ] do
        assert_raise ArgumentError, ~r/is for a :forbidden refusal/, fn -> answer(who, path) end
      end
    end

    # The envelope is JSON, which such a name cannot be written into.
    test "a service name that is not UTF-8 is refused without being echoed" do
      mine = app("mine")

      for {method, message} <- [
            {"GET", "Caller not authorized for this service"},
            {"POST", "Caller may not provide this service"},
            {"DELETE", "Caller may not delete this service"}
          ] do
        assert decide(mine, "/services/%FF", method) == {:error, :forbidden}
        assert answer(mine, "/services/%FF", method) == {403, message}
        assert answer(mine, "/services/mq%C3%28tt", method) == {403, message}
      end
    end

    test "a lattice refusal is the plain 403" do
      assert answer(principal(:default), "/store") == {403, "unauthorized"}
      assert answer(principal(:none), "/addons/probe/stats") == {403, "unauthorized"}
      assert answer(principal(:manager), "/ingress/session", "POST") == {403, "unauthorized"}
    end

    # A predicate refuses every method. Where the router serves none, the
    # caller is told what the router would have said.
    test "a predicate refusal on a method the route does not serve is the router's 404" do
      mine = app("mine")

      for {path, method} <- [
            {"/addons/theirs/info", "POST"},
            {"/addons/theirs/stats", "DELETE"},
            {"/addons/mine/security", "GET"},
            {"/ingress/session", "GET"},
            {"/auth", "DELETE"},
            {"/services/mqtt", "PUT"},
            {"/services/mqtt", "get"}
          ] do
        assert decide(mine, path, method) == {:error, :forbidden}
        assert answer(mine, path, method) == {404, "not found"}, "#{method} #{path}"
      end

      # A tier refusal is 403 whatever the method.
      assert answer(principal(:default), "/addons/probe/stats", "POST") == {403, "unauthorized"}
    end

    # Every method the router serves on a predicate row's path has an answer,
    # and no other does: a route added there has to be given one.
    test "a row answers exactly the methods the router serves on its path" do
      routed = Enum.group_by(@fixture, & &1["path"], & &1["method"])
      rows = for row <- @fixture, row["predicates"] != %{}, do: row
      assert rows != []

      for row <- rows do
        {_requirement, columns} =
          row["path"] |> segments() |> Vagus.API.Tiers.required_with_predicates()

        assert columns[:answer] |> Map.keys() |> Enum.sort() == Enum.sort(routed[row["path"]]),
               row["path"]
      end
    end

    test "a predicate refusal is what the row's handler says" do
      mine = app("mine")
      not_yours = {403, "Not authorized for this add-on"}

      for tail <- ~w(info stats logs logs/latest logs/follow logs/boots/0 logs/boots/0/follow) do
        assert answer(mine, "/addons/theirs/#{tail}") == not_yours, tail
      end

      assert answer(mine, "/addons/vagus/info") == not_yours

      assert answer(mine, "/addons/theirs/options/config") ==
               {403, "This can be only read by the app itself!"}

      assert answer(mine, "/addons/mine/security", "POST") == {403, "unauthorized"}
      assert answer(mine, "/ingress/session", "POST") == {401, "unauthorized"}
      assert answer(mine, "/ingress/validate_session", "POST") == {401, "unauthorized"}

      auth = {403, "Caller is not allowed to access the auth API"}
      assert answer(mine, "/auth") == auth
      assert answer(:supervisor, "/auth", "POST") == auth
    end

    test "a refused service is named as its handler names it, by method" do
      mine = app("mine")

      assert answer(mine, "/services/mqtt", "GET") == {403, "Caller not authorized for 'mqtt'"}
      assert answer(mine, "/services/mqtt", "POST") == {403, "Caller may not provide 'mqtt'"}
      assert answer(mine, "/services/mqtt", "DELETE") == {403, "Caller may not delete 'mqtt'"}
      # The decoded segment, as the handler would have read it.
      assert answer(mine, "/services/my%20sql", "GET") ==
               {403, "Caller not authorized for 'my sql'"}
    end
  end

  describe "refusal_label/1" do
    test "names the requirement, never the path" do
      label = fn path ->
        Authz.refusal_label({:rest, :supervisor_api, "GET", segments(path)}, ctx(path))
      end

      assert label.("/store") == "authz/manager"
      assert label.("/core/restart") == "authz/supervisor"
      assert label.("/zz-marker/\e[31m") == "authz/admin"
    end

    test "names the stricter of the two spellings' requirements" do
      label = fn path ->
        Authz.refusal_label({:rest, :supervisor_api, "POST", segments(path)}, ctx(path))
      end

      # raw homeassistant, decoded supervisor
      assert label.("/core/%72estart") == "authz/supervisor"
      # raw admin, decoded bypass
      assert label.("/%69nfo") == "authz/admin"
    end

    test "names the predicates a row carries, and still never the path" do
      label = fn path ->
        Authz.refusal_label({:rest, :supervisor_api, "GET", segments(path)}, ctx(path))
      end

      assert label.("/addons/zz-marker\e[31m/info") == "authz/default+subject"
      assert label.("/addons/zz-marker/stats") == "authz/manager+subject"
      assert label.("/addons/zz-marker/security") == "authz/admin+caller"
      assert label.("/ingress/session") == "authz/admin+caller"
      assert label.("/auth") == "authz/bypass+requires"
      assert label.("/services/zz-marker") == "authz/bypass+requires"
      # A handler-decided row has nothing the table enforces to name.
      assert label.("/discovery") == "authz/bypass"
      # The stricter requirement, and the predicates of either spelling.
      assert label.("/%61uth") == "authz/admin+requires"
      assert label.("/addons/%73elf/info") == "authz/default+subject"
    end
  end
end
