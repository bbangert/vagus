defmodule Vagus.API.StaticDataTest do
  # async: false — these tests mutate the :vagus application env
  # (`:machine`) to prove the value is read at runtime rather than baked in
  # at compile time.
  use ExUnit.Case, async: false

  alias Vagus.API.StaticData

  describe "machine (board identity)" do
    test "root_info/0 and core_info/0 report the CONFIGURED machine, not a literal" do
      configured = Application.get_env(:vagus, :machine)

      # Guard the guard: if config/test.exs ever stops setting the key, this
      # test would otherwise pass vacuously against StaticData's fallback.
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

    test "arch stays fixed across boards — both targets are aarch64" do
      assert StaticData.root_info()[:arch] == "aarch64"
      assert StaticData.root_info()[:supported_arch] == ["aarch64"]
      assert StaticData.core_info()[:arch] == "aarch64"
    end
  end
end
