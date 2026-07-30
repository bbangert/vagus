defmodule Vagus.API.SupervisorOptionsTest do
  use ExUnit.Case, async: true

  alias Vagus.API.SupervisorOptions

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "vagus_test_supervisor_options_#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  # An explicit :id (matching :name) rather than the {SupervisorOptions, opts}
  # shorthand - that shorthand's child_spec/1 always derives id:
  # SupervisorOptions, which would collide across the multiple
  # differently-named instances some of these tests start, and wouldn't be
  # stop_supervised!-able by name (mirrors token_store_test.exs).
  defp start_store(path, name \\ nil) do
    name = name || :"supervisor_options_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: name,
      start: {SupervisorOptions, :start_link, [[name: name, path: path]]}
    })

    name
  end

  describe "put/2 + get/1 round-trip" do
    test "a posted field is readable back", %{path: path} do
      store = start_store(path)

      assert SupervisorOptions.get(store) == %{timezone: nil, country: nil, diagnostics: nil}

      assert :ok = SupervisorOptions.put(%{"timezone" => "Europe/Amsterdam"}, store)
      assert SupervisorOptions.timezone(store) == "Europe/Amsterdam"
      assert SupervisorOptions.get(store).timezone == "Europe/Amsterdam"
    end

    test "all three persisted fields round-trip together", %{path: path} do
      store = start_store(path)

      fields = %{"timezone" => "UTC", "country" => "NL", "diagnostics" => true}
      assert :ok = SupervisorOptions.put(fields, store)

      assert SupervisorOptions.get(store) == %{
               timezone: "UTC",
               country: "NL",
               diagnostics: true
             }
    end

    test "diagnostics: false persists distinctly from never-posted (nil)", %{path: path} do
      store = start_store(path)

      assert :ok = SupervisorOptions.put(%{"diagnostics" => false}, store)
      assert SupervisorOptions.get(store).diagnostics == false
    end

    test "unknown fields are ignored gracefully", %{path: path} do
      store = start_store(path)

      assert :ok =
               SupervisorOptions.put(
                 %{"timezone" => "UTC", "totally_unknown_field" => "nope"},
                 store
               )

      assert SupervisorOptions.timezone(store) == "UTC"
    end

    test "a put with none of the persisted keys is still :ok and changes nothing", %{path: path} do
      store = start_store(path)

      assert :ok = SupervisorOptions.put(%{"channel" => "beta"}, store)
      assert SupervisorOptions.get(store) == %{timezone: nil, country: nil, diagnostics: nil}
    end

    test "a later put only overrides the fields it carries", %{path: path} do
      store = start_store(path)

      assert :ok = SupervisorOptions.put(%{"timezone" => "UTC", "country" => "NL"}, store)
      assert :ok = SupervisorOptions.put(%{"country" => "US"}, store)

      assert SupervisorOptions.get(store) == %{
               timezone: "UTC",
               country: "US",
               diagnostics: nil
             }
    end
  end

  describe "file persistence across process restart (boot reload)" do
    test "a value posted before a restart is still there after, via a fresh server on the same path",
         %{path: path} do
      store = start_store(path, :persistence_test_supervisor_options_store)

      assert :ok =
               SupervisorOptions.put(
                 %{"timezone" => "Europe/Amsterdam", "country" => "NL", "diagnostics" => true},
                 store
               )

      stop_supervised!(store)
      start_supervised!({SupervisorOptions, name: store, path: path})

      assert SupervisorOptions.get(store) == %{
               timezone: "Europe/Amsterdam",
               country: "NL",
               diagnostics: true
             }
    end

    test "starting fresh against a nonexistent file has no persisted fields", %{path: path} do
      refute File.exists?(path)
      store = start_store(path)
      assert SupervisorOptions.get(store) == %{timezone: nil, country: nil, diagnostics: nil}
    end

    test "a corrupt/malformed-JSON file is treated like a missing one, and a later put repairs it",
         %{path: path} do
      :ok = File.mkdir_p(Path.dirname(path))
      File.write!(path, "not json { at all")

      store1 = start_store(path)
      assert SupervisorOptions.get(store1) == %{timezone: nil, country: nil, diagnostics: nil}

      assert :ok = SupervisorOptions.put(%{"timezone" => "UTC"}, store1)
      stop_supervised!(store1)

      store2 = start_store(path, :repair_test_supervisor_options_store)
      assert SupervisorOptions.timezone(store2) == "UTC"
    end
  end

  # W3 — the persisted file is not trusted verbatim on load: a wrongly-typed
  # field (hand-edited file, partial write) is dropped (nil), not passed
  # through to raise later inside GET /info.
  describe "decode discipline on load (W3)" do
    test "a wrong-typed field loads as nil, valid siblings still load, a warning is logged",
         %{path: path} do
      :ok = File.mkdir_p(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(%{"diagnostics" => "yes", "timezone" => "UTC", "country" => 123})
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          store = start_store(path)

          assert SupervisorOptions.get(store) == %{
                   timezone: "UTC",
                   country: nil,
                   diagnostics: nil
                 }
        end)

      assert log =~ "diagnostics"
      assert log =~ "country"
    end

    test "a non-map decoded value for a field is dropped, not raised on", %{path: path} do
      :ok = File.mkdir_p(Path.dirname(path))
      File.write!(path, Jason.encode!(%{"timezone" => %{"nested" => "map"}}))

      store = start_store(path)
      assert SupervisorOptions.timezone(store) == nil
    end

    test "a fully valid file round-trips through a fresh load unchanged", %{path: path} do
      :ok = File.mkdir_p(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(%{
          "timezone" => "Europe/Amsterdam",
          "country" => "NL",
          "diagnostics" => true
        })
      )

      store = start_store(path)

      assert SupervisorOptions.get(store) == %{
               timezone: "Europe/Amsterdam",
               country: "NL",
               diagnostics: true
             }
    end
  end
end
