defmodule Vagus.Addon.ContainerFingerprintTest do
  @moduledoc """
  Does an add-on Vagus starts *look from the inside* like one a real Supervisor
  started?

  `Manager.build_spec/2` and `Backend.Container.build_config/1` were written
  against upstream's `docker/addon.py`, and the tests around them assert the
  Docker JSON matches what we believe upstream asks for. Belief is the weak
  part: every one of those assertions restates our own reading of upstream back
  to itself, so a misread stays green forever. This compares instead against
  `test/fixtures/haos-2026.07.5-container-fingerprint.json` — captured from
  inside an add-on container on a real Home Assistant Green by reading its
  `/proc`, `/etc/hosts`, `/etc/resolv.conf`, environment and mount table.

  ## What is compared, and what deliberately is not

  Only facts the fixture actually witnessed, and only in the direction that
  carries information:

    * Env is asserted one-way (Spec's keys ⊆ the container's). The rest of the
      environment — `BINDIR`, `EMU`, `MIX_ENV`, `PATH` — belongs to the image
      and its base OS, not to the Supervisor, so requiring the reverse would
      gate Vagus on the probe add-on's Dockerfile.
    * Token *values* are never compared. The probe redacts them to
      `"<redacted N bytes>"`; that the key arrived with a redacted value is the
      whole assertion (injection happened), and a fixture carrying live
      Supervisor tokens would be a secret in git.
    * Mounts are asserted both ways, because that direction is where upstream
      grows things silently. A fixture mount nothing explains fails the test.

  ## Regenerating the fixture

  Requires the bench: install the `probe_*` add-ons from the bench add-on
  repository, then `POST /eval` with `Jason.encode!(fingerprint_report())` on
  the Elixir probe and pipe the response through `jq -S .`. The report records
  the Supervisor version it came from, and the filename must agree with it.
  """

  use ExUnit.Case, async: true

  alias Vagus.Addon.Backend.Container
  alias Vagus.Addon.{Config, Manager}
  alias Vagus.Network
  alias Vagus.ProbeParity.Canon

  @fixture_path Path.join([
                  __DIR__,
                  "..",
                  "..",
                  "fixtures",
                  "haos-2026.07.5-container-fingerprint.json"
                ])
  @external_resource @fixture_path
  @fixture @fixture_path |> File.read!() |> Jason.decode!()

  @supervisor_version @fixture_path
                      |> Path.basename()
                      |> String.replace_prefix("haos-", "")
                      |> String.replace_suffix("-container-fingerprint.json", "")

  @fingerprint @fixture["fingerprint"]
  @identity @fixture["identity"]

  # The bench host's zone, fed back in as the `:tz` opt. The TZ assertion below
  # is therefore a round trip of the fixture's own value — it measures that Spec
  # passes the opt through, not that Vagus derives the right zone, which nothing
  # in the capture could tell us.
  @tz @fingerprint["env"]["TZ"]

  # Mount targets every container on this engine has, whoever created it: the
  # overlay root, the masked/read-only `/proc` and `/sys` subtrees runc applies,
  # the standard `/dev` device mounts, the three files the daemon binds in
  # (`/etc/hostname`, `/etc/hosts`, `/etc/resolv.conf`) and the engine's own
  # `/dev/shm`. `/proc/*` and `/sys/*` are matched by prefix: the exact set of
  # masked paths is a runc version detail and pinning it would make this a runc
  # test.
  @engine_baseline [
    "/",
    "/dev/hugepages",
    "/dev/mqueue",
    "/dev/pts",
    "/dev/shm",
    "/etc/hostname",
    "/etc/hosts",
    "/etc/resolv.conf",
    "/proc",
    "/sys"
  ]
  @engine_baseline_prefixes ["/proc/", "/sys/"]

  # Divergences reviewed and accepted. Same discipline as
  # `Vagus.API.PermissionMatrixTest`: an entry is a decision with a reason, not
  # a silenced failure, and anything not listed fails loudly.
  # The other direction: mounts VAGUS declares that the real Supervisor does
  # not. Same discipline as `@accepted_mounts` — a decision with a reason, and
  # anything not listed fails loudly. A `/dev/null` mask over `/dev/console`
  # briefly lived here and was removed once it was shown that `mknod` walks
  # around it (docs/divergences.md), which is exactly the kind of claim this
  # ledger exists to stop being made casually.
  #
  # Empty because every mount this fixture's spec declares is one upstream has
  # too — NOT because Vagus adds none. `dsp: true` adds two (`/usr/lib/dsp` and
  # the skel store at `/usr/lib/rfsa/adsp`), and they cannot be ledgered here:
  # the fixture is a real Supervisor add-on, which has no `dsp:`, so the spec
  # under test never declares them and the "still real" assertion below would
  # fail on the entry. They are ledgered in docs/divergences.md instead.
  @vagus_only_mounts %{}

  @accepted_mounts %{
    # Upstream writes a cid file per add-on under the Supervisor's
    # `cid_files/` and binds it read-only at `/run/cid`, so an add-on can read
    # the id of the container it is running in. `mounts/2` creates no such
    # file, so a Vagus add-on that reads `/run/cid` finds nothing.
    "/run/cid" => "ro bind of a per-add-on cid file upstream writes; Vagus creates none"
  }

  # Every flag the probe reports, on every mount, true or false. A fixed and
  # complete key set is what lets the volatile allowlist mask the atime family:
  # Canon substitutes a sentinel rather than deleting, so a flag that were
  # merely absent when off would mask as `:absent` on one side and `<volatile>`
  # on the other.
  @mount_flags ~w(dirsync lazytime noatime nodev nodiratime noexec nosuid nosymfollow
                  relatime strictatime sync)

  # The flags an add-on can escalate through. Deliberately not in the volatile
  # allowlist: masking these is how a Vagus capture with an suid-enabled or
  # executable mount would have compared equal to a locked-down HAOS one.
  @policy_flags ~w(nodev noexec nosuid)

  @redacted ~r/^<redacted \d+ bytes>$/

  # A run long and dense enough to be a key, a token or a hash. Slashes, dots,
  # colons and dashes end a run, which is what keeps host paths, version strings
  # and IPv6 addresses out of it.
  @entropy_run ~r/[A-Za-z0-9+=]{32,}/
  @container_id ~r/^[0-9a-f]{64}$/

  @accepted_dns_options %{
    # Not produced by `build_spec/2`, and not obviously the Supervisor's either:
    # libnetwork writes `options ndots:0` into the resolv.conf of a container it
    # serves with embedded DNS, which fits the `127.0.0.11` nameserver beside it.
    # Recorded rather than chased, because "add ndots:0 to Spec" would be a
    # guess: if the engine writes it, Vagus gets it for free, and if upstream
    # sets it, Spec is missing it. Pending investigation.
    "ndots:0" => "observed in HAOS resolv.conf; likely engine embedded-DNS, not Spec — unverified"
  }

  setup_all do
    {:ok, config} =
      Config.parse(%{
        "name" => "Elixir probe",
        "version" => @identity["version"],
        "slug" => @identity["slug"],
        "description" => "bench probe",
        "arch" => [@fixture["versions"]["arch"]],
        "image" => "ghcr.io/bbangert/ha-bench-addons/elixir_probe",
        "init" => false,
        "boot" => "manual",
        "startup" => "application",
        "homeassistant_api" => @identity["homeassistant_api"],
        "hassio_api" => @identity["hassio_api"],
        "ports" => %{"4000/tcp" => 4000}
      })

    spec =
      Manager.build_spec(config,
        access_token: "fingerprint-token",
        arch: @fixture["versions"]["arch"],
        data_root: "/mnt/data/supervisor",
        tz: @tz
      )

    %{spec: spec, host_config: Container.build_config(spec)["HostConfig"]}
  end

  test "the fixture records the Supervisor version its filename claims" do
    assert @fixture["versions"]["supervisor"] == @supervisor_version
  end

  test "every env var Spec injects reached the container", %{spec: spec} do
    env = @fingerprint["env"]

    for key <- Map.keys(spec.env) do
      assert Map.has_key?(env, key), "Spec injects #{key}, but the real add-on had no such var"
    end

    assert env["TZ"] == spec.env["TZ"]

    # Both sides, because either alone passes vacuously: the loop above stops
    # checking a key Spec stopped injecting, and the fixture's redaction only
    # ever witnesses what the bench's Supervisor did. Values cannot be compared
    # — the probe redacts them — so non-empty on the Spec side plus redacted on
    # the container side is the most the pair can say.
    for key <- ["SUPERVISOR_TOKEN", "HASSIO_TOKEN"] do
      assert Map.get(spec.env, key) not in [nil, ""], "Spec no longer injects #{key}"
      assert String.starts_with?(env[key], "<redacted ")
    end
  end

  test "the container's hostname is the slug with underscores dashed", %{spec: spec} do
    expected = String.replace(@identity["slug"], "_", "-")

    assert @fingerprint["hostname"] == expected
    assert spec.hostname == expected
  end

  test "resolver search domain and options match, ndots aside", %{spec: spec} do
    resolv = @fingerprint["resolv_conf"]

    assert spec.dns_search == resolv["search"]

    # The fixture's only nameserver is 127.0.0.11 — the engine's embedded DNS
    # resolver, which forwards to whatever `--dns` the container was created
    # with. `Spec.dns` (the Supervisor DNS plugin address, 172.30.32.3) is that
    # upstream, and is invisible from inside the container, so comparing the two
    # would be comparing an engine artifact to a Vagus setting.
    assert resolv["nameservers"] == ["127.0.0.11"]

    for option <- spec.dns_options do
      assert option in resolv["options"], "Spec sets #{option}, absent from the real resolv.conf"
    end

    unexplained =
      Enum.reject(resolv["options"] -- spec.dns_options, &Map.has_key?(@accepted_dns_options, &1))

    assert unexplained == [], """
    The real add-on's resolv.conf carries options Spec does not set and the
    ledger does not explain: #{inspect(unexplained)}
    """
  end

  test "supervisor and hassio resolve to the bridge anchor", %{spec: spec} do
    for {name, ip} <- spec.extra_hosts do
      entry = Enum.find(@fingerprint["etc_hosts"], &(name in &1["names"]))

      assert entry, "Spec injects host #{name}, absent from the real /etc/hosts"
      assert entry["ip"] == ip
    end

    # Guards the assertion above against passing vacuously if Spec ever stops
    # injecting these: they are half the add-on contract (`http://supervisor/`).
    assert Map.keys(spec.extra_hosts) |> Enum.sort() == ["hassio", "supervisor"]
    assert spec.extra_hosts["supervisor"] == Network.supervisor_ip()
  end

  # A target can appear more than once: the fixture witnessed two `/dev/shm`
  # entries, the engine's own plus the Supervisor's tmpfs stacked over it. Both
  # of the mount tests below therefore check every entry sharing the target, so
  # one of a duplicated pair regressing cannot hide behind the other.
  test "Spec's tmpfs entries exist as tmpfs in the container", %{spec: spec} do
    # Named before the loop, because a Spec that stopped declaring tmpfs would
    # iterate nothing and pass, and `/dev/shm` is in @engine_baseline besides,
    # so the reverse test would not notice either.
    assert Map.has_key?(spec.tmpfs, "/dev/shm")

    # Both halves of the duplicate, so the Supervisor's tmpfs vanishing on a
    # regenerated fixture cannot hide behind the engine's own.
    assert length(Enum.filter(@fingerprint["mounts"], &(&1["target"] == "/dev/shm"))) == 2

    # Open question, unverified. The two `/dev/shm` entries disagree on noexec:
    # the engine's own has it, the Supervisor's tmpfs stacked over it does not.
    # Vagus asks for `%{"/dev/shm" => ""}` — an empty option string — which
    # leaves the engine to apply its own defaults, and those conventionally
    # include noexec. If that is what happens, a Vagus add-on that execs out of
    # /dev/shm breaks where an upstream one works. Nothing here can settle it:
    # it needs a container fingerprint captured from a Vagus device, which does
    # not exist yet, and comparing that capture's `/dev/shm` flags against this
    # fixture's is the whole answer.

    for target <- Map.keys(spec.tmpfs) do
      mounts = Enum.filter(@fingerprint["mounts"], &(&1["target"] == target))

      assert mounts != [], "Spec mounts tmpfs at #{target}, absent from the real mount table"
      assert Enum.all?(mounts, &(&1["fstype"] == "tmpfs"))
    end
  end

  test "every mount Spec declares is present in the container", %{spec: spec} do
    # This is what pins the `/dev` bind read-only: the fixture's `/dev` is
    # `ro: true`, so a Spec that bound it writable would fail here rather than
    # anywhere device-specific. Intended coupling, not incidental.
    for %{target: target} = mount <- spec.mounts,
        not Map.has_key?(@vagus_only_mounts, target) do
      fixture_mounts = Enum.filter(@fingerprint["mounts"], &(&1["target"] == target))

      assert fixture_mounts != [], "Spec mounts #{target}, absent from the real mount table"

      # Sources are host paths and differ by machine and data-root layout; the
      # comparable facts are that the target exists and its writability agrees.
      assert Enum.all?(fixture_mounts, &(&1["ro"] == Map.get(mount, :read_only, false)))
    end
  end

  test "every mount the container has is explained", %{spec: spec} do
    explained = Map.keys(spec.tmpfs) ++ Enum.map(spec.mounts, & &1.target)

    unexplained =
      @fingerprint["mounts"]
      |> Enum.map(& &1["target"])
      |> Enum.uniq()
      |> Enum.reject(fn target ->
        target in explained or engine_baseline?(target) or
          Map.has_key?(@accepted_mounts, target)
      end)

    assert unexplained == [], """
    The real add-on has mounts neither Spec nor the engine baseline explains:

    #{inspect(unexplained)}

    A new one is the point of this test: either Vagus should create it, or it
    belongs in @accepted_mounts with a reason.
    """
  end

  test "the mount table's security flags survived as comparable structure" do
    mounts = @fingerprint["mounts"]

    for mount <- mounts do
      assert Map.keys(mount["flags"]) |> Enum.sort() == @mount_flags,
             "#{mount["target"]} reports #{inspect(Map.keys(mount["flags"]))}, not the full set"
    end

    # Non-vacuity, without pinning totals that any upstream mount addition would
    # churn: the bench witnessed each of these somewhere, so a fixture where one
    # is nowhere true has lost hardening rather than gained a mount.
    for flag <- @policy_flags do
      assert Enum.any?(mounts, & &1["flags"][flag]),
             "no mount carries #{flag}; the real Supervisor's add-on had several"
    end

    # Ties the booleans to the string they were extracted from, which is what
    # keeps them from being stubbed: masking options is only safe while the
    # flags still say everything the option string said.
    for mount <- mounts, flag <- @mount_flags do
      assert mount["flags"][flag] == flag in String.split(mount["options"], ","),
             "#{mount["target"]}: flags.#{flag} disagrees with options #{mount["options"]}"
    end
  end

  # `/dev` left this ledger when `mounts/2` started binding it. One assertion
  # did NOT survive the move: the fixture's `/dev` is `devtmpfs`, and no Spec
  # test can check that, because Spec has no `fstype` — the test above compares
  # target and `ro` only. Accepted: a bind of the host's `/dev` reports the
  # source fs's type, so there is nothing Vagus chooses here to regress.
  test "each declared divergence is still real — declared by Spec, absent upstream", %{spec: spec} do
    # Without this the ledger rots: an entry for a mount Spec stopped
    # declaring, or one upstream has since adopted, would silently keep
    # excusing itself in the test above.
    for {target, reason} <- @vagus_only_mounts do
      assert Enum.any?(spec.mounts, &(&1.target == target)),
             "#{target} is ledgered as a Vagus-only mount but Spec no longer declares it"

      refute Enum.any?(@fingerprint["mounts"], &(&1["target"] == target)),
             "#{target} is ledgered as a divergence (#{reason}) but the real add-on has it too"
    end
  end

  test "the accepted mount gaps are still exactly what was accepted" do
    cid = Enum.find(@fingerprint["mounts"], &(&1["target"] == "/run/cid"))

    # The source is what proves this is the Supervisor's doing and not the
    # engine's, which is the whole reason it counts as a Vagus gap.
    assert cid["source"] =~ ~r{/supervisor/cid_files/.+\.cid$}
    assert cid["ro"] == true
  end

  test "OomScoreAdj, seccomp and pid 1 match what the backend stamps", %{
    spec: spec,
    host_config: host_config
  } do
    assert @fingerprint["proc"]["oom_score_adj"] == host_config["OomScoreAdj"]

    # /proc/self/status Seccomp: 0 is SECCOMP_MODE_DISABLED — the observable
    # consequence of `seccomp=unconfined`, which is what the backend stamps.
    assert @fingerprint["status"]["Seccomp"] == "0"
    assert "seccomp=unconfined" in host_config["SecurityOpt"]

    # `init: false` means no docker-init shim, so the image's own entrypoint is
    # pid 1 — beam.smp here, which is only true if nothing was injected above it.
    assert spec.init == false
    assert host_config["Init"] == false
    assert @fingerprint["proc"]["pid1_comm"] == "beam.smp"
  end

  test "every credential-shaped env var was committed redacted" do
    # Shared with `mix vagus.probe.diff`, which withholds values on a
    # credential-shaped path: what this test demands be redacted and what that
    # task refuses to print have to be the same set of keys.
    keys = @fingerprint["env"] |> Map.keys() |> Enum.filter(&(&1 =~ Canon.credential_key()))

    # The probe redacts by its own key regex, which is narrower than this one.
    # An unredacted value reaching git is the thing to catch, and it would reach
    # it through a key the probe's regex missed.
    assert keys != []

    for key <- keys do
      assert @fingerprint["env"][key] =~ @redacted,
             "#{key} was committed with a value the probe did not redact"
    end
  end

  test "the fixture carries no high-entropy string beyond the engine's container id" do
    unexplained =
      @fixture
      |> strings([])
      |> Enum.flat_map(fn {path, value} ->
        @entropy_run |> Regex.scan(value) |> Enum.map(fn [run] -> {path, run} end)
      end)
      |> Enum.reject(&container_id?/1)

    assert unexplained == [], """
    The fixture carries strings dense enough to be keys or tokens:

    #{inspect(unexplained)}

    A capture is committed to git, so anything here is public. Either the probe
    failed to redact it, or this scan needs a narrower reason to allow it.
    """
  end

  # The daemon names each container's config directory after the container's
  # 64-hex id, so its own bind sources carry one. It names a container on a
  # bench box that no longer exists, and is not a secret.
  defp container_id?({path, run}) do
    String.starts_with?(path, "fingerprint/mounts/") and String.ends_with?(path, "/source") and
      run =~ @container_id
  end

  defp strings(value, path) when is_map(value) do
    Enum.flat_map(value, fn {key, child} -> strings(child, [key | path]) end)
  end

  defp strings(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, index} -> strings(child, [Integer.to_string(index) | path]) end)
  end

  defp strings(value, path) when is_binary(value) do
    [{path |> Enum.reverse() |> Enum.join("/"), value}]
  end

  defp strings(_value, _path), do: []

  defp engine_baseline?(target) do
    target in @engine_baseline or
      Enum.any?(@engine_baseline_prefixes, &String.starts_with?(target, &1))
  end
end
