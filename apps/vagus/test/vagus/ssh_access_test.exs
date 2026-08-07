defmodule Vagus.SSHAccessTest do
  @moduledoc """
  `Vagus.SSHAccess` — the device-managed ed25519 SSH access key: keygen,
  DETS persistence, and the hand-rolled `openssh-key-v1` private-key PEM
  encoder. Every test starts its own privately-named/tabled instance against
  a tmp DETS path (`config :vagus, :ssh_access_enabled, false` in
  `config/test.exs` keeps the app-started instance out of the way).
  """
  use ExUnit.Case, async: false

  alias Vagus.SSHAccess

  setup do
    dir = Path.join(System.tmp_dir!(), "ssh_access_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "ssh_access.dets")
    table = :"ssh_access_test_#{System.unique_integer([:positive])}"
    name = :"ssh_access_srv_#{System.unique_integer([:positive])}"

    {:ok, pid} = SSHAccess.start_link(name: name, table: table, dets_path: path)

    on_exit(fn ->
      # The server is linked to the (already-dead) test process, so it may be
      # shutting down concurrently — alive?-then-stop is a TOCTOU race that
      # exits with :shutdown under CI load. Stop unconditionally and swallow
      # the already-dead exit.
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(dir)
    end)

    {:ok, name: name, table: table, path: path}
  end

  test "exposes an ed25519 OpenSSH public key", %{name: name} do
    pub = SSHAccess.public_key(name)
    assert String.starts_with?(pub, "ssh-ed25519 ")

    # The line parses as a valid OpenSSH authorized_keys entry.
    assert [{{{:ECPoint, _point}, {:namedCurve, {1, 3, 101, 112}}}, _attrs}] =
             :ssh_file.decode(pub, :auth_keys)
  end

  test "exposes a SHA256 fingerprint matching the public key", %{name: name} do
    fp = SSHAccess.fingerprint(name)
    assert String.starts_with?(fp, "SHA256:")

    [{pub_rec, _}] = :ssh_file.decode(SSHAccess.public_key(name), :auth_keys)
    assert fp == to_string(:ssh.hostkey_fingerprint(:sha256, pub_rec))
  end

  test "exposes an unencrypted OpenSSH private key PEM", %{name: name} do
    priv = SSHAccess.private_key(name)
    assert String.starts_with?(priv, "-----BEGIN OPENSSH PRIVATE KEY-----\n")
    assert String.ends_with?(priv, "-----END OPENSSH PRIVATE KEY-----\n")
  end

  test "the private PEM body decodes to an openssh-key-v1 blob embedding the published public point",
       %{name: name} do
    priv = SSHAccess.private_key(name)
    pub = SSHAccess.public_key(name)

    [{{{:ECPoint, point}, {:namedCurve, _}}, _attrs}] = :ssh_file.decode(pub, :auth_keys)

    body =
      priv
      |> String.trim_leading("-----BEGIN OPENSSH PRIVATE KEY-----\n")
      |> String.trim_trailing("-----END OPENSSH PRIVATE KEY-----\n")
      |> String.trim()

    decoded = Base.decode64!(body, ignore: :whitespace)

    assert String.starts_with?(decoded, "openssh-key-v1\0")
    assert :binary.match(decoded, point) != :nomatch
  end

  # Tagged so a stripped image without OpenSSH can exclude it
  # (`--exclude ssh_keygen`); when it runs, a missing ssh-keygen fails loudly
  # rather than passing with zero assertions. The devcontainer ships
  # ssh-keygen, so this runs by default here; the executable check also lets
  # it no-op cleanly on a host without one, without needing a CLI flag.
  @tag :ssh_keygen
  test "the private key round-trips to the published public key", %{name: name} do
    keygen = System.find_executable("ssh-keygen")

    if keygen do
      tmp = Path.join(System.tmp_dir!(), "ssh_rt_#{System.unique_integer([:positive])}")
      File.write!(tmp, SSHAccess.private_key(name))
      File.chmod!(tmp, 0o600)
      on_exit(fn -> File.rm_rf!(tmp) end)

      {derived, 0} = System.cmd(keygen, ["-y", "-f", tmp])
      # Compare the "<type> <base64-blob>" prefix, ignoring the comment field.
      [type, blob | _] = String.split(SSHAccess.public_key(name), " ")
      assert String.starts_with?(String.trim(derived), "#{type} #{blob}")
    end
  end

  test "persists the keypair across restarts", %{name: name, table: table, path: path} do
    first = %{
      public_key: SSHAccess.public_key(name),
      private_key: SSHAccess.private_key(name),
      fingerprint: SSHAccess.fingerprint(name)
    }

    :ok = GenServer.stop(name)

    name2 = :"ssh_access_srv_#{System.unique_integer([:positive])}"
    {:ok, _pid} = SSHAccess.start_link(name: name2, table: table, dets_path: path)

    assert SSHAccess.public_key(name2) == first.public_key
    assert SSHAccess.private_key(name2) == first.private_key
    assert SSHAccess.fingerprint(name2) == first.fingerprint
  end

  test "generate_keypair/0 produces distinct keys each call" do
    a = SSHAccess.generate_keypair()
    b = SSHAccess.generate_keypair()
    assert a.public_key != b.public_key
    assert a.fingerprint != b.fingerprint
  end

  test "starting on the host (no NervesSSH) completes ensure_key cleanly and still serves public_key",
       %{name: name} do
    # NervesSSH is a target-only dependency, absent from this host build —
    # `handle_continue(:ensure_key, ...)` already ran by the time
    # `start_link/1` returned above, so if the missing-NervesSSH branch in
    # `authorize/1` crashed instead of skipping, the server would already be
    # dead. A `GenServer.call` forces synchronization and proves it's alive
    # and responsive.
    assert Process.alive?(GenServer.whereis(name))
    assert String.starts_with?(SSHAccess.public_key(name), "ssh-ed25519 ")
  end
end
