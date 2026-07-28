defmodule Vagus.Addon.OptionsSchemaTest do
  use ExUnit.Case, async: true

  alias Vagus.Addon.OptionsSchema, as: S

  describe "scalar tokens" do
    test "str with and without length bounds" do
      assert {:ok, %{"a" => "hi"}} = S.validate(%{"a" => "str"}, %{"a" => "hi"})
      assert {:ok, %{"a" => "hello"}} = S.validate(%{"a" => "str(2,10)"}, %{"a" => "hello"})
      assert {:error, msg} = S.validate(%{"a" => "str(3,)"}, %{"a" => "hi"})
      assert msg =~ "shorter than 3"
      assert {:error, msg} = S.validate(%{"a" => "str(,4)"}, %{"a" => "toolong"})
      assert msg =~ "longer than 4"
      assert {:error, _} = S.validate(%{"a" => "str"}, %{"a" => 5})
    end

    test "int coerces from string and enforces range incl. negatives" do
      assert {:ok, %{"a" => 5}} = S.validate(%{"a" => "int"}, %{"a" => "5"})
      assert {:ok, %{"a" => -3}} = S.validate(%{"a" => "int(-10,0)"}, %{"a" => -3})
      assert {:error, m} = S.validate(%{"a" => "int(1,10)"}, %{"a" => 0})
      assert m =~ "below 1"
      assert {:error, m} = S.validate(%{"a" => "int(1,10)"}, %{"a" => 11})
      assert m =~ "above 10"
      assert {:error, _} = S.validate(%{"a" => "int"}, %{"a" => "notanint"})
    end

    test "float coerces and ranges with decimals" do
      assert {:ok, %{"a" => 1.5}} = S.validate(%{"a" => "float"}, %{"a" => "1.5"})
      assert {:ok, %{"a" => 2.0}} = S.validate(%{"a" => "float"}, %{"a" => 2})
      assert {:error, _} = S.validate(%{"a" => "float(0,1.0)"}, %{"a" => 2.5})
    end

    test "bool accepts the usual spellings" do
      for {v, e} <- [
            {true, true},
            {"true", true},
            {"yes", true},
            {"on", true},
            {1, true},
            {false, false},
            {"no", false},
            {"off", false},
            {0, false}
          ] do
        assert {:ok, %{"a" => ^e}} = S.validate(%{"a" => "bool"}, %{"a" => v})
      end

      assert {:error, _} = S.validate(%{"a" => "bool"}, %{"a" => "maybe"})
    end

    test "port range 1..65535" do
      assert {:ok, %{"a" => 1883}} = S.validate(%{"a" => "port"}, %{"a" => "1883"})
      assert {:error, _} = S.validate(%{"a" => "port"}, %{"a" => 0})
      assert {:error, _} = S.validate(%{"a" => "port"}, %{"a" => 70_000})
    end

    test "email and url" do
      assert {:ok, _} = S.validate(%{"a" => "email"}, %{"a" => "x@y.z"})
      assert {:error, _} = S.validate(%{"a" => "email"}, %{"a" => "nope"})
      assert {:ok, _} = S.validate(%{"a" => "url"}, %{"a" => "https://host/path"})
      assert {:error, _} = S.validate(%{"a" => "url"}, %{"a" => "host"})
    end

    test "match() is anchored at the start (re.match semantics)" do
      assert {:ok, %{"a" => "abc123"}} = S.validate(%{"a" => "match([a-z]+)"}, %{"a" => "abc123"})
      # anchored at start: leading digits fail
      assert {:error, _} = S.validate(%{"a" => "match([a-z]+)"}, %{"a" => "1abc"})
    end

    test "list(a|b|c) enum membership, value stringified" do
      assert {:ok, %{"a" => "b"}} = S.validate(%{"a" => "list(a|b|c)"}, %{"a" => "b"})
      assert {:error, m} = S.validate(%{"a" => "list(a|b|c)"}, %{"a" => "z"})
      assert m =~ "must be one of"
    end

    test "unknown type token errors" do
      assert {:error, m} = S.validate(%{"a" => "bogus"}, %{"a" => "x"})
      assert m =~ "Unknown type 'bogus'"
    end
  end

  describe "optionality + required" do
    test "optional (?) key may be absent" do
      assert {:ok, m} = S.validate(%{"a" => "str?"}, %{})
      refute Map.has_key?(m, "a")
    end

    test "present optional key is still validated" do
      assert {:error, _} = S.validate(%{"a" => "int?"}, %{"a" => "nope"})
    end

    test "missing required key errors" do
      assert {:error, m} = S.validate(%{"a" => "str"}, %{})
      assert m =~ "Missing option 'a'"
    end

    test "present-but-nil required key errors" do
      assert {:error, m} = S.validate(%{"a" => "str"}, %{"a" => nil})
      assert m =~ "Missing required option 'a'"
    end

    test "optional one-element list may be absent" do
      assert {:ok, m} = S.validate(%{"a" => ["str?"]}, %{})
      refute Map.has_key?(m, "a")
    end
  end

  describe "unknown keys" do
    test "keys absent from the schema are dropped, not errors" do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          assert {:ok, %{"a" => "x"} = out} =
                   S.validate(%{"a" => "str"}, %{"a" => "x", "extra" => 1})

          refute Map.has_key?(out, "extra")
        end)

      assert log =~ "does not exist in the schema"
    end
  end

  describe "nested structures" do
    test "nested map recurses" do
      schema = %{"customize" => %{"active" => "bool", "folder" => "str"}}

      assert {:ok, %{"customize" => %{"active" => true, "folder" => "m"}}} =
               S.validate(schema, %{"customize" => %{"active" => "true", "folder" => "m"}})

      assert {:error, _} =
               S.validate(schema, %{"customize" => %{"active" => "x", "folder" => "m"}})
    end

    test "list of scalars" do
      assert {:ok, %{"a" => [1, 2, 3]}} = S.validate(%{"a" => ["int"]}, %{"a" => ["1", 2, "3"]})
      assert {:error, m} = S.validate(%{"a" => ["int"]}, %{"a" => "notalist"})
      assert m =~ "must be a list"
    end

    test "list of dicts (logins shape)" do
      schema = %{"logins" => [%{"username" => "str", "password" => "password"}]}

      assert {:ok, %{"logins" => [%{"username" => "u", "password" => "p"}]}} =
               S.validate(schema, %{"logins" => [%{"username" => "u", "password" => "p"}]})

      assert {:error, m} = S.validate(schema, %{"logins" => [%{"username" => "u"}]})
      assert m =~ "Missing option 'password'"
    end
  end

  describe "merge/2 (deepmerge semantics)" do
    test "maps merge recursively; scalars and lists overridden by user" do
      defaults = %{"a" => 1, "nested" => %{"x" => 1, "y" => 2}, "list" => [1, 2]}
      user = %{"a" => 9, "nested" => %{"y" => 20, "z" => 30}, "list" => [9]}

      assert S.merge(defaults, user) == %{
               "a" => 9,
               "nested" => %{"x" => 1, "y" => 20, "z" => 30},
               "list" => [9]
             }
    end
  end

  describe "schema: false" do
    test "passes options through unchanged" do
      assert {:ok, %{"anything" => 1}} = S.validate(false, %{"anything" => 1})
    end
  end

  describe "!secret resolution" do
    test "resolves from the secrets map, then types" do
      assert {:ok, %{"a" => "s3cret"}} =
               S.validate(%{"a" => "str"}, %{"a" => "!secret pw"}, secrets: %{"pw" => "s3cret"})
    end

    test "unknown secret errors" do
      assert {:error, m} = S.validate(%{"a" => "str"}, %{"a" => "!secret nope"})
      assert m =~ "Unknown secret 'nope'"
    end
  end

  describe "malformed schema robustness (untrusted add-on config → error, never crash)" do
    test "malformed schema elements are errors, not FunctionClauseError crashes" do
      for bad <- [[], ["str", "int"], false, 123, %{"k" => []}] do
        assert {:error, _} = S.validate(%{"a" => bad}, %{"a" => "x"})
      end
    end

    test "unparseable numeric bounds (bare '-') are treated as unbounded, not a crash" do
      assert {:ok, %{"a" => 1.5}} = S.validate(%{"a" => "float(-,)"}, %{"a" => 1.5})
      assert {:ok, %{"a" => 7}} = S.validate(%{"a" => "int(-,)"}, %{"a" => 7})
    end
  end

  describe "match() ReDoS mitigation" do
    test "input over the byte cap is rejected before matching" do
      big = String.duplicate("a", 5_000)
      assert {:error, m} = S.validate(%{"a" => "match([a-z]+)"}, %{"a" => big})
      assert m =~ "match limit"
    end

    test "a catastrophic-backtracking regex returns quickly (match_limit-bounded)" do
      # (a+)+$ against non-matching input is the classic ReDoS; match_limit caps
      # the backtracking so this fails fast instead of pinning the scheduler.
      schema = %{"a" => "match((a+)+$)"}
      value = %{"a" => String.duplicate("a", 40) <> "!"}

      {micros, result} = :timer.tc(fn -> S.validate(schema, value) end)
      assert {:error, _} = result
      assert micros < 1_000_000, "match should be bounded, took #{micros}us"
    end
  end

  describe "Mosquitto add-on schema (v7.1.0) end-to-end" do
    @mosquitto_schema %{
      "logins" => [
        %{"username" => "str", "password" => "password", "password_pre_hashed" => "bool?"}
      ],
      "log_dest" => ["list(none|stdout|stderr|topic)?"],
      "log_type" => [
        "list(none|debug|error|warning|notice|information|subscribe|unsubscribe|websockets|all)?"
      ],
      "require_certificate" => "bool",
      "certfile" => "str",
      "cafile" => "str?",
      "keyfile" => "str",
      "customize" => %{"active" => "bool", "folder" => "str"},
      "debug" => "bool?"
    }

    @mosquitto_defaults %{
      "logins" => [],
      "require_certificate" => false,
      "certfile" => "fullchain.pem",
      "keyfile" => "privkey.pem",
      "customize" => %{"active" => false, "folder" => "mosquitto"}
    }

    test "defaults alone validate (no user options)" do
      assert {:ok, out} = S.effective(@mosquitto_schema, @mosquitto_defaults, %{})
      assert out["require_certificate"] == false
      assert out["customize"] == %{"active" => false, "folder" => "mosquitto"}
      # optional absent keys stay absent
      refute Map.has_key?(out, "cafile")
      refute Map.has_key?(out, "debug")
      refute Map.has_key?(out, "log_dest")
    end

    test "user login list overrides the empty default and validates" do
      user = %{"logins" => [%{"username" => "svc", "password" => "pw"}]}
      assert {:ok, out} = S.effective(@mosquitto_schema, @mosquitto_defaults, user)
      assert out["logins"] == [%{"username" => "svc", "password" => "pw"}]
    end

    test "optional log_type enum members validate" do
      user = %{"log_type" => ["error", "warning"]}
      assert {:ok, out} = S.effective(@mosquitto_schema, @mosquitto_defaults, user)
      assert out["log_type"] == ["error", "warning"]
    end

    test "invalid log_type enum member is rejected" do
      user = %{"log_type" => ["bogus"]}
      assert {:error, m} = S.effective(@mosquitto_schema, @mosquitto_defaults, user)
      assert m =~ "must be one of"
    end
  end

  describe "ui/1 — the form the Configuration page builds" do
    # `nil` here is what drops the frontend into its YAML editor, which is
    # what every add-on got while this was hardcoded.
    defp node(schema, name), do: S.ui(schema) |> Enum.find(&(&1["name"] == name))

    test "an add-on with no schema has no form" do
      assert S.ui(false) == nil
    end

    test "an empty schema is a form with no fields, which is not the same thing" do
      assert S.ui(%{}) == []
    end

    test "each token maps to the type the frontend knows how to render" do
      schema = %{
        "s" => "str",
        "i" => "int",
        "f" => "float",
        "b" => "bool",
        "p" => "password",
        "e" => "email",
        "u" => "url",
        "port" => "port",
        "m" => "match(^a.*$)",
        "l" => "list(x|y|z)"
      }

      assert node(schema, "s")["type"] == "string"
      assert node(schema, "i")["type"] == "integer"
      assert node(schema, "f")["type"] == "float"
      assert node(schema, "b")["type"] == "boolean"
      assert node(schema, "port")["type"] == "integer"
      assert node(schema, "m")["type"] == "string"

      # Every emitted type must be in the frontend's SUPPORTED_UI_TYPES, or it
      # silently falls back to YAML for the whole add-on.
      supported = ~w(string select boolean integer float schema)
      assert Enum.all?(S.ui(schema), &(&1["type"] in supported))
    end

    test "password, email and url are strings with a format" do
      schema = %{"p" => "password", "e" => "email", "u" => "url"}

      assert node(schema, "p") == %{
               "name" => "p",
               "type" => "string",
               "format" => "password",
               "required" => true
             }

      assert node(schema, "e")["format"] == "email"
      assert node(schema, "u")["format"] == "url"
    end

    test "a list token becomes a select carrying its options" do
      assert node(%{"l" => "list(debug|info|error)"}, "l") == %{
               "name" => "l",
               "type" => "select",
               "options" => ["debug", "info", "error"],
               "required" => true
             }
    end

    test "bounds ride along as floats, the way upstream emits them" do
      assert node(%{"s" => "str(1,10)"}, "s")["lengthMin"] === 1.0
      assert node(%{"s" => "str(1,10)"}, "s")["lengthMax"] === 10.0
      assert node(%{"i" => "int(0,100)"}, "i")["lengthMin"] === 0.0
      assert node(%{"f" => "float(1.5,2.5)"}, "f")["lengthMax"] === 2.5

      # An unbounded token carries neither key rather than nulls.
      refute Map.has_key?(node(%{"s" => "str"}, "s"), "lengthMin")
    end

    test "the trailing ? is the required/optional split, and exactly one is set" do
      required = node(%{"a" => "str"}, "a")
      optional = node(%{"a" => "str?"}, "a")

      assert required["required"] == true
      refute Map.has_key?(required, "optional")
      assert optional["optional"] == true
      refute Map.has_key?(optional, "required")
    end

    test "a one-element list renders that element as multiple" do
      assert node(%{"keys" => ["str"]}, "keys") == %{
               "name" => "keys",
               "type" => "string",
               "multiple" => true,
               "required" => true
             }
    end

    test "a nested map becomes a schema node holding its children" do
      assert node(%{"server" => %{"tcp_forwarding" => "bool?"}}, "server") == %{
               "name" => "server",
               "type" => "schema",
               "optional" => true,
               "multiple" => false,
               "schema" => [
                 %{"name" => "tcp_forwarding", "type" => "boolean", "optional" => true}
               ]
             }
    end

    test "an unrenderable token is skipped, not fatal to the rest of the form" do
      # Upstream's `_single_ui_option` returns early on a regex miss. Losing
      # one field beats losing the form.
      ui = S.ui(%{"good" => "str", "bad" => "nonsense"})

      assert Enum.map(ui, & &1["name"]) == ["good"]
    end

    test "the real Terminal & SSH schema renders every field" do
      # The add-on that surfaced this: its form was a YAML editor because
      # `schema` was hardcoded null.
      schema = %{
        "authorized_keys" => ["str"],
        "apks" => ["str"],
        "password" => "password?",
        "server" => %{"tcp_forwarding" => "bool?"}
      }

      ui = S.ui(schema)
      assert length(ui) == 4
      assert node(schema, "password")["format"] == "password"
      assert node(schema, "password")["optional"] == true
      assert node(schema, "authorized_keys")["multiple"] == true
      assert node(schema, "server")["type"] == "schema"
    end
  end
end
