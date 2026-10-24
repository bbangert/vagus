defmodule Vagus.PatchesTest do
  # Compiles and loads real throwaway modules, each named per test.
  use ExUnit.Case, async: true

  alias Vagus.Patches

  @moduletag :capture_log

  setup do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "patches_#{n}")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, n: n}
  end

  defp start(root, opts \\ []) do
    name = :"patches_#{System.unique_integer([:positive])}"

    defaults = [
      name: name,
      enabled: true,
      root: root,
      boot_complete?: fn -> false end,
      poll_ms: 5
    ]

    start_supervised!({Patches, Keyword.merge(defaults, opts)}, id: name)
    [server: name]
  end

  defp mod(n, suffix \\ ""), do: Module.concat([Vagus.PatchTest, "M#{n}#{suffix}"])

  defp source(mod, value),
    do: "defmodule #{inspect(mod)} do\n  def marker, do: #{inspect(value)}\nend\n"

  defp patch(root, name, files, opts \\ []) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    if Keyword.get(opts, :notes, true), do: File.write!(Path.join(dir, "NOTES.md"), "why\n")
    if Keyword.get(opts, :enabled, false), do: File.touch!(Path.join(dir, "enabled"))
    for {file, body} <- files, do: File.write!(Path.join(dir, file), body)
    dir
  end

  defp boot(root), do: root |> Path.join(".boot") |> File.read!() |> Jason.decode!()

  test "load makes the module live, and a second load replaces it", %{root: root, n: n} do
    s = start(root)
    m = mod(n)
    dir = patch(root, "p", [{"m.ex", source(m, :one)}])

    assert Patches.load("p", s) == {:ok, [m]}
    assert m.marker() == :one

    File.write!(Path.join(dir, "m.ex"), source(m, :two))
    assert Patches.load("p", s) == {:ok, [m]}
    assert m.marker() == :two

    assert [%{name: "p", modules: [^m], loaded?: true, last_result: :ok, enabled?: false}] =
             Patches.list(s)
  end

  test "unload purges a module the code path does not have", %{root: root, n: n} do
    s = start(root)
    m = mod(n)
    patch(root, "p", [{"m.ex", source(m, :one)}])
    {:ok, [^m]} = Patches.load("p", s)

    assert Patches.unload("p", s) == {:ok, [m]}
    refute Code.ensure_loaded?(m)
    assert [%{loaded?: false}] = Patches.list(s)
  end

  test "unload restores the code path's beam", %{root: root, n: n} do
    m = mod(n)
    ebin = Path.join(root, "ebin")
    File.mkdir_p!(ebin)
    [{^m, bin}] = Code.compile_string(source(m, :release))
    File.write!(Path.join(ebin, "#{m}.beam"), bin)
    Code.prepend_path(ebin)
    on_exit(fn -> Code.delete_path(ebin) end)

    s = start(root)
    patch(root, "p", [{"m.ex", source(m, :patched)}])
    {:ok, [^m]} = Patches.load("p", s)
    assert m.marker() == :patched

    assert Patches.unload("p", s) == {:ok, [m]}
    assert m.marker() == :release
  end

  test "a patch without notes is refused", %{root: root, n: n} do
    s = start(root)
    patch(root, "p", [{"m.ex", source(mod(n), :one)}], notes: false)
    assert Patches.load("p", s) == {:error, :no_notes}
    refute Code.ensure_loaded?(mod(n))
  end

  test "names that could leave the root are refused", %{root: root} do
    s = start(root)

    for name <- ["../x", "a/b", "..", ".boot", "a b", ""] do
      assert Patches.load(name, s) == {:error, :invalid_name}
    end

    assert Patches.load("absent", s) == {:error, :not_found}
    assert Patches.enable("absent", s) == {:error, :not_found}
  end

  test "a compile error names the file and stops before the next", %{root: root, n: n} do
    s = start(root)
    good = mod(n, "Good")

    patch(root, "p", [
      {"a_bad.ex", "defmodule #{inspect(mod(n, "Bad"))} do\n  def x, do: y\nend\n"},
      {"b_good.ex", source(good, :one)}
    ])

    assert {:error, {:compile, "a_bad.ex", message}} = Patches.load("p", s)
    assert message =~ "undefined variable"
    refute Code.ensure_loaded?(good)
    assert [%{loaded?: false, last_result: {:error, {:compile, "a_bad.ex", _}}}] = Patches.list(s)
  end

  test "enable, disable and list", %{root: root, n: n} do
    s = start(root)
    m = mod(n)
    patch(root, "p", [{"m.ex", source(m, :one)}])

    assert [%{name: "p", enabled?: false, modules: [^m], loaded?: false, last_result: nil}] =
             Patches.list(s)

    assert Patches.enable("p", s) == :ok
    assert [%{enabled?: true}] = Patches.list(s)
    assert Patches.disable("p", s) == :ok
    assert Patches.disable("p", s) == :ok
    assert [%{enabled?: false}] = Patches.list(s)
  end

  test "boot_load loads only enabled patches, each on its own", %{root: root, n: n} do
    s = start(root)
    on = mod(n, "On")
    off = mod(n, "Off")
    patch(root, "a_broken", [{"x.ex", "defmodule"}], enabled: true)
    patch(root, "b_on", [{"m.ex", source(on, :on)}], enabled: true)
    patch(root, "c_off", [{"m.ex", source(off, :off)}])

    assert {:ok, %{"a_broken" => {:error, {:compile, "x.ex", _}}, "b_on" => :ok} = results} =
             Patches.boot_load(s)

    assert map_size(results) == 2
    assert on.marker() == :on
    refute Code.ensure_loaded?(off)

    assert %{"patches" => ["a_broken", "b_on"], "good" => false, "loaded_at" => _} =
             written = boot(root)

    assert %{"b_on" => "ok", "a_broken" => "{:error, {:compile" <> _} = written["results"]
    # Once per server: a second call does not trip on its own record.
    assert Patches.boot_load(s) == {:ok, results}
  end

  test "a boot with no enabled patches is good at once", %{root: root} do
    s = start(root)
    assert Patches.boot_load(s) == {:ok, %{}}
    assert %{"patches" => [], "good" => true} = boot(root)
  end

  test "the breaker skips every patch once after a boot never marked good", %{
    root: root,
    n: n
  } do
    m = mod(n)
    patch(root, "p", [{"m.ex", source(m, :one)}], enabled: true)
    previous = %{"loaded_at" => "x", "patches" => ["p"], "results" => %{}, "good" => false}
    File.write!(Path.join(root, ".boot"), Jason.encode!(previous))

    s = start(root)
    assert Patches.boot_load(s) == {:ok, :skipped}
    refute Code.ensure_loaded?(m)

    assert %{"reason" => "previous boot not marked good", "previous" => ^previous, "at" => _} =
             root |> Path.join(".skipped") |> File.read!() |> Jason.decode!()

    assert %{"patches" => [], "good" => true} = boot(root)

    s = start(root)
    assert {:ok, %{"p" => :ok}} = Patches.boot_load(s)
    assert m.marker() == :one
  end

  test "mark_good flips the record", %{root: root, n: n} do
    s = start(root)
    patch(root, "p", [{"m.ex", source(mod(n), :one)}], enabled: true)
    assert Patches.mark_good(s) == {:error, :no_boot}
    {:ok, _} = Patches.boot_load(s)
    assert Patches.mark_good(s) == :ok
    assert %{"good" => true, "patches" => ["p"]} = boot(root)
  end

  test "marks good itself once the boot completed and the delay passed", %{root: root, n: n} do
    test_pid = self()
    patch(root, "p", [{"m.ex", source(mod(n), :one)}], enabled: true)

    complete? = fn ->
      send(test_pid, :asked)
      true
    end

    s = start(root, boot_complete?: complete?, good_after_ms: 10)
    {:ok, _} = Patches.boot_load(s)
    assert_receive :asked, 1_000
    # The list call is served after the check that answered :asked.
    Patches.list(s)
    assert %{"good" => true} = boot(root)
  end

  test "not marked good while the boot has not completed", %{root: root, n: n} do
    test_pid = self()
    patch(root, "p", [{"m.ex", source(mod(n), :one)}], enabled: true)

    s =
      start(root,
        boot_complete?: fn -> send(test_pid, :asked) && false end,
        good_after_ms: 0
      )

    {:ok, _} = Patches.boot_load(s)
    assert_receive :asked, 1_000
    assert_receive :asked, 1_000
    assert %{"good" => false} = boot(root)
  end

  test "a clean stop marks the boot good", %{root: root, n: n} do
    patch(root, "p", [{"m.ex", source(mod(n), :one)}], enabled: true)
    [server: name] = s = start(root, poll_ms: 60_000)
    {:ok, _} = Patches.boot_load(s)
    assert %{"good" => false} = boot(root)

    stop_supervised!(name)
    assert %{"good" => true} = boot(root)
  end

  test "an absent server answers an error, never an exit" do
    s = [server: :"absent_#{System.unique_integer([:positive])}"]
    assert Patches.list(s) == {:error, :not_running}
    assert Patches.load("p", s) == {:error, :not_running}
    assert Patches.boot_load(s) == {:error, :not_running}
    assert Patches.mark_good(s) == {:error, :not_running}
  end

  test "off the flavor it does not start" do
    assert Patches.start_link(enabled: false) == :ignore
  end
end
