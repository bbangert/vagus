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

  describe "the lattice" do
    test "each principal reaches exactly the requirements it should" do
      for {who, reaches} <- @reaches, {requirement, path} <- @paths do
        expected = if requirement in reaches, do: :ok, else: refusal(who)

        assert authorize(who, path) == expected,
               "#{who} on #{path} (#{requirement}): expected #{inspect(expected)}"
      end
    end

    test "every route decides as its pinned requirement says, for every principal" do
      for row <- @fixture, {who, reaches} <- @reaches do
        requirement = String.to_existing_atom(row["requirement"])
        expected = if requirement in reaches, do: :ok, else: refusal(who)

        assert authorize(who, row["path"], row["method"]) == expected,
               "#{who} on #{row["method"]} #{row["path"]}: expected #{inspect(expected)}"
      end
    end

    test "the supervisor satisfies every row, and the fallback" do
      for {method, _route, path} <- RouterRoutes.instances() do
        assert authorize(:supervisor, path, method) == :ok
      end

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
      for path <- ~w(/info /services /discovery /auth /addons/self/info) do
        assert authorize(:none, path) == :ok
        assert authorize(:anonymous, path) == {:error, :unauthenticated}
      end
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
  end
end
