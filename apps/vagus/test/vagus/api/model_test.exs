defmodule Vagus.API.ModelTest do
  use ExUnit.Case, async: true

  # A throwaway model, local to this test module, exercising
  # Vagus.API.Model's macro in isolation from any real response shape.
  defmodule Sample do
    use Vagus.API.Model,
      required: [:a],
      nullable: [:b]
  end

  describe "build!/1" do
    test "returns the map unchanged when required + nullable keys are all supplied" do
      assert Sample.build!(%{a: 1, b: 2}) == %{a: 1, b: 2}
    end

    test "nullable keys default to nil when omitted" do
      assert Sample.build!(%{a: 1}) == %{a: 1, b: nil}
    end

    test "a caller-supplied value for a nullable key wins over the nil default" do
      assert Sample.build!(%{a: 1, b: "concrete"}) == %{a: 1, b: "concrete"}
    end

    test "a missing required key raises in strict mode (config/test.exs sets model_strict: true)" do
      assert_raise ArgumentError, ~r/missing=\[:a\]/, fn ->
        Sample.build!(%{b: 2})
      end
    end

    test "an undeclared/extra key raises in strict mode" do
      assert_raise ArgumentError, ~r/extra=\[:c\]/, fn ->
        Sample.build!(%{a: 1, b: 2, c: "surprise"})
      end
    end
  end
end
