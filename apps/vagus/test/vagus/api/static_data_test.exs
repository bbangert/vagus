defmodule Vagus.API.StaticDataTest do
  # async: false — these tests mutate the :vagus application env
  # (`:machine`) to prove the value is read at runtime rather than baked in
  # at compile time.
  use ExUnit.Case, async: false

  import Mox

  alias Vagus.API.StaticData

  # `root_info/0` calls `Vagus.Backend.os().info()`, so this module needs a
  # live OS mock. It cannot rely on the ambient `stub_with/2` delegation
  # from test_helper.exs: Mox's global mode ties stub ownership to whichever
  # process last called `set_mox_global/1`, and
  # `Vagus.API.RouterBackendTest` re-claims it for itself (see its
  # moduledoc). Both modules are `async: false`, so they share the sync
  # phase and the ambient stubs are already dead if that module ran first —
  # which is exactly how this failed in CI (seed 661416) while passing
  # locally under a seed that ordered it the other way. Re-claiming
  # ownership and re-stubbing here makes the module order-independent.
  setup :set_mox_global

  setup do
    stub_with(Vagus.Backend.OSMock, Vagus.Backend.OS.HostStub)
    :ok
  end

  describe "machine (board identity)" do
    test "root_info/0 and core_info/0 report the CONFIGURED machine, not a literal" do
      configured = Application.get_env(:vagus, :machine)

      # Not a vacuous-pass guard — without it this test would still fail if
      # the key went missing (`StaticData.machine/0` raises now, and even
      # under the old defaulted read a nil `configured` could not match a
      # non-nil fallback). It exists purely to turn that into a one-line
      # "you forgot config/test.exs" instead of a KeyError or a confusing
      # nil-vs-string diff.
      refute is_nil(configured),
             "config :vagus, :machine must be set (see config/test.exs)"

      assert StaticData.root_info()[:machine] == configured
      assert StaticData.core_info()[:machine] == configured
    end

    test "both endpoints follow a target that configures a different machine" do
      # "generic-aarch64" is what config/dragon_q6a.exs sets — a real HAOS
      # machine, and the reason this value stopped being a module attribute.
      original = Application.get_env(:vagus, :machine)
      Application.put_env(:vagus, :machine, "generic-aarch64")
      on_exit(fn -> Application.put_env(:vagus, :machine, original) end)

      assert StaticData.root_info()[:machine] == "generic-aarch64"
      assert StaticData.core_info()[:machine] == "generic-aarch64"
    end

    test "raises rather than reporting some other board when the key is missing" do
      original = Application.get_env(:vagus, :machine)
      Application.delete_env(:vagus, :machine)
      on_exit(fn -> Application.put_env(:vagus, :machine, original) end)

      # The point of the config indirection: a board that forgets to set
      # :machine must fail loudly, not quietly claim to be a Raspberry Pi.
      assert_raise ArgumentError, fn -> StaticData.root_info() end
      assert_raise ArgumentError, fn -> StaticData.core_info() end
    end

    test "arch stays fixed across boards — both targets are aarch64" do
      assert StaticData.root_info()[:arch] == "aarch64"
      assert StaticData.root_info()[:supported_arch] == ["aarch64"]
      assert StaticData.core_info()[:arch] == "aarch64"
    end
  end
end
