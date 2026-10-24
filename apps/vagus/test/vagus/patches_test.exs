defmodule Vagus.PatchesTest do
  # Compiles and loads real throwaway modules, each named per test.
  use ExUnit.Case, async: true

  alias Vagus.Patches

  @moduletag :capture_log

  setup do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "patches_#{n}")
    # unique_integer repeats across VMs, and a VM killed mid-run leaves its roots.
    File.rm_rf!(root)

    on_exit(fn ->
      new_vm_boot(root)
      File.chmod(root, 0o755)
      File.rm_rf(root)
    end)

    %{root: root, n: n}
  end

  # What a reboot clears: the marker that says this VM already ran boot_load,
  # and the inventory of what is loaded.
  defp new_vm_boot(root) do
    :persistent_term.erase({Patches, :boot_done, Path.expand(root)})
    :persistent_term.erase({Patches, :inventory, Path.expand(root)})
  end

  defp restart(name) do
    pid = GenServer.whereis(name)
    Process.exit(pid, :kill)
    eventually(fn -> GenServer.whereis(name) not in [nil, pid] end)
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

  defp bad_boot(root) do
    File.mkdir_p!(root)
    previous = %{"loaded_at" => "x", "patches" => ["p"], "results" => %{}, "good" => false}
    File.write!(Path.join(root, ".boot"), Jason.encode!(previous))
    previous
  end

  defp eventually(fun, tries \\ 400) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(5) && eventually(fun, tries - 1)
    end
  end

  defp booted(s, tries \\ 400) do
    assert {:ok, :started} = Patches.boot_load(s)
    eventually(fn -> match?({:done, _}, Patches.boot_status(s)) end, tries)
    {:done, results} = Patches.boot_status(s)
    results
  end

  # A module body runs at compile time, so it can report or block from there.
  defp hook(mod, body), do: "defmodule #{inspect(mod)} do\n  #{body}\nend\n"
  defp pid_literal, do: "~c\"#{:erlang.pid_to_list(self())}\" |> :erlang.list_to_pid()"

  describe "load and unload" do
    test "load makes the module live, and a second load replaces it", %{root: root, n: n} do
      s = start(root)
      m = mod(n)
      dir = patch(root, "p", [{"m.ex", source(m, :one)}])

      assert Patches.load("p", s) == {:ok, [m]}
      assert m.marker() == :one

      File.write!(Path.join(dir, "m.ex"), source(m, :two))
      assert Patches.load("p", s) == {:ok, [m]}
      assert m.marker() == :two

      assert [
               %{
                 name: "p",
                 modules: [^m],
                 loaded?: true,
                 last_result: :ok,
                 enabled?: false,
                 in_use: [],
                 purged?: true
               }
             ] = Patches.list(s)
    end

    test "unload removes a module the code path does not have", %{root: root, n: n} do
      s = start(root)
      m = mod(n)
      patch(root, "p", [{"m.ex", source(m, :one)}])
      {:ok, [^m]} = Patches.load("p", s)

      assert Patches.unload("p", s) == {:ok, [m]}
      assert :code.is_loaded(m) == false
      assert [%{loaded?: false}] = Patches.list(s)
    end

    # Checked through :code.is_loaded/1, not a call: the release runs
    # embedded, where nothing autoloads a module unload left out.
    test "unload loads the code path's beam back", %{root: root, n: n} do
      m = mod(n)
      ebin = Path.join(root, "ebin")
      File.mkdir_p!(ebin)
      [{^m, bin}] = Code.compile_string(source(m, :release))
      :code.delete(m)
      :code.purge(m)
      File.write!(Path.join(ebin, "#{m}.beam"), bin)
      Code.prepend_path(ebin)
      on_exit(fn -> Code.delete_path(ebin) end)

      s = start(root)
      patch(root, "p", [{"m.ex", source(m, :patched)}])
      {:ok, [^m]} = Patches.load("p", s)
      assert m.marker() == :patched

      assert Patches.unload("p", s) == {:ok, [m]}
      assert {:file, path} = :code.is_loaded(m)
      assert to_string(path) =~ ebin
      assert m.marker() == :release
    end

    test "old code a process still runs is reported, never purged", %{root: root, n: n} do
      s = start(root, purge_ms: 5, purge_tries: 1_000)
      m = mod(n)

      wait =
        "def wait, do: send(#{pid_literal()}, {:entered, self()}) && receive(do: (:stop -> :ok))"

      dir = patch(root, "p", [{"m.ex", hook(m, "def v, do: 1\n  #{wait}")}])
      {:ok, [^m]} = Patches.load("p", s)

      {pid, ref} = spawn_monitor(fn -> m.wait() end)
      # Entered before the reload, so it runs what becomes the old code.
      assert_receive {:entered, ^pid}
      File.write!(Path.join(dir, "m.ex"), hook(m, "def v, do: 2\n  #{wait}"))
      assert Patches.load("p", s) == {:ok, [m]}
      assert m.v() == 2
      assert [%{in_use: [^m], purged?: false}] = Patches.list(s)

      # A third load would purge the old code under the process.
      assert Patches.load("p", s) == {:error, {:in_use, [m]}}
      assert Process.alive?(pid)

      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      eventually(fn -> match?([%{in_use: [], purged?: true}], Patches.list(s)) end)
      assert Patches.load("p", s) == {:ok, [m]}
    end

    test "any old code still running refuses every load", %{root: root, n: n} do
      s = start(root)
      proto = mod(n, "Proto")
      impl = Module.concat(proto, Integer)
      wait = "send(#{pid_literal()}, {:entered, self()}) && receive(do: (:stop -> :ok))"

      impl_src = fn v ->
        "defimpl #{inspect(proto)}, for: Integer do\n  def a(_), do: #{v} && #{wait}\nend\n"
      end

      patch(root, "proto", [{"a.ex", "defprotocol #{inspect(proto)} do\n  def a(x)\nend\n"}])
      dir = patch(root, "one", [{"b.ex", impl_src.(1)}])
      patch(root, "two", [{"b.ex", impl_src.(2)}])
      {:ok, _} = Patches.load("proto", s)
      {:ok, [^impl]} = Patches.load("one", s)

      {holder, _ref} = spawn_monitor(fn -> proto.a(1) end)
      assert_receive {:entered, ^holder}
      File.write!(Path.join(dir, "b.ex"), impl_src.(3))
      {:ok, [^impl]} = Patches.load("one", s)

      # Its defimpl is unknown to "two" before compiling, and would purge the holder's code.
      assert Patches.load("two", s) == {:error, {:in_use, [impl]}}
      assert Process.alive?(holder)
      send(holder, :stop)
    end

    test "a later file redefining a module is refused while its old code runs", %{
      root: root,
      n: n
    } do
      s = start(root)
      m = mod(n)

      wait =
        "def wait, do: send(#{pid_literal()}, {:entered, self()}) && receive(do: (:stop -> :ok))"

      patch(root, "base", [{"m.ex", hook(m, "def v, do: 0\n  #{wait}")}])
      {:ok, [^m]} = Patches.load("base", s)
      {holder, _ref} = spawn_monitor(fn -> m.wait() end)
      assert_receive {:entered, ^holder}

      patch(root, "p", [{"a.ex", hook(m, "def v, do: 1")}, {"b.ex", hook(m, "def v, do: 2")}])
      assert Patches.load("p", s) == {:error, {:in_use, [m]}}
      assert m.v() == 1
      assert Process.alive?(holder)
      assert [_base, %{name: "p", modules: [^m], loaded?: true}] = Patches.list(s)
      send(holder, :stop)
    end

    test "a restart keeps tracking old code a process still runs", %{root: root, n: n} do
      [server: name] = s = start(root, purge_ms: 5, purge_tries: 1_000)
      m = mod(n)

      wait =
        "def wait, do: send(#{pid_literal()}, {:entered, self()}) && receive(do: (:stop -> :ok))"

      dir = patch(root, "p", [{"m.ex", hook(m, "def v, do: 1\n  #{wait}")}])
      {:ok, [^m]} = Patches.load("p", s)
      {holder, ref} = spawn_monitor(fn -> m.wait() end)
      assert_receive {:entered, ^holder}
      File.write!(Path.join(dir, "m.ex"), hook(m, "def v, do: 2\n  #{wait}"))
      {:ok, [^m]} = Patches.load("p", s)

      restart(name)
      assert [%{in_use: [^m], purged?: false}] = Patches.list(s)

      send(holder, :stop)
      assert_receive {:DOWN, ^ref, :process, ^holder, :normal}
      eventually(fn -> match?([%{in_use: [], purged?: true}], Patches.list(s)) end)
    end

    test "a file defining a module twice is refused before it loads", %{root: root, n: n} do
      s = start(root)
      m = mod(n)
      first = mod(n, "First")

      wait =
        "def wait, do: send(#{pid_literal()}, {:entered, self()}) && receive(do: (:stop -> :ok))"

      # The release's version, which a process is running.
      Code.compile_string(hook(m, "def v, do: 0\n  #{wait}"))
      {holder, _ref} = spawn_monitor(fn -> m.wait() end)
      assert_receive {:entered, ^holder}

      patch(root, "p", [
        {"a.ex", source(first, :one)},
        {"b.ex", hook(m, "def v, do: 1") <> hook(m, "def v, do: 2")}
      ])

      assert Patches.load("p", s) == {:error, {:duplicate_module, "b.ex", m}}
      assert m.v() == 0
      assert Process.alive?(holder)
      assert [%{modules: [^first], loaded?: true}] = Patches.list(s)
      send(holder, :stop)
    end

    test "a module a macro emits twice is reported", %{root: root, n: n} do
      s = start(root)
      mac = mod(n, "Mac")
      twice = mod(n, "Twice")

      macro =
        "defmacro twice(name) do\n    quote do\n      defmodule unquote(name) do\n      end\n\n" <>
          "      defmodule unquote(name) do\n      end\n    end\n  end"

      patch(root, "p", [
        {"a.ex", hook(mac, macro)},
        {"b.ex", "require #{inspect(mac)}\n#{inspect(mac)}.twice(#{inspect(twice)})\n"}
      ])

      assert Patches.load("p", s) == {:error, {:repeated_module, [twice]}}

      assert [%{last_result: {:error, {:repeated_module, [^twice]}}, loaded?: true}] =
               Patches.list(s)
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

      assert [%{loaded?: false, last_result: {:error, {:compile, "a_bad.ex", _}}}] =
               Patches.list(s)
    end

    test "modules a failing file loaded before its failure are recorded", %{root: root, n: n} do
      s = start(root)
      first = mod(n, "First")
      outer = mod(n, "Outer")
      inner = Module.concat(outer, Inner)

      body =
        source(first, :one) <>
          "defmodule #{inspect(outer)} do\n  defmodule Inner do\n    def x, do: 1\n  end\nend\n" <>
          hook(mod(n, "Raises"), "raise \"boom\"")

      patch(root, "p", [{"a.ex", body}])

      assert {:error, {:compile, "a.ex", message}} = Patches.load("p", s)
      assert message =~ "boom"
      assert [%{loaded?: true, modules: modules}] = Patches.list(s)
      assert Enum.sort(modules) == Enum.sort([first, outer, inner])

      assert Patches.unload("p", s) == {:ok, modules}
      for m <- modules, do: assert(:code.is_loaded(m) == false)
    end

    test "modules a macro emitted before a failure are recorded", %{root: root, n: n} do
      s = start(root)
      proto = mod(n, "Proto")
      impl = Module.concat(proto, Integer)

      patch(root, "p", [
        {"a.ex", "defprotocol #{inspect(proto)} do\n  def a(x)\nend\n"},
        {"b.ex",
         "defimpl #{inspect(proto)}, for: Integer do\n  def a(x), do: x\nend\nraise \"boom\"\n"}
      ])

      assert {:error, {:compile, "b.ex", _}} = Patches.load("p", s)
      assert [%{modules: modules}] = Patches.list(s)
      assert Enum.sort(modules) == Enum.sort([proto, impl])

      assert Patches.unload("p", s) == {:ok, modules}
      assert :code.is_loaded(impl) == false
    end

    test "a restart keeps what live loads and unloads changed", %{root: root, n: n} do
      a = mod(n, "A")
      b = mod(n, "B")
      dir = patch(root, "p", [{"a.ex", source(a, :one)}], enabled: true)
      patch(root, "q", [{"m.ex", source(mod(n, "Q"), :one)}])
      [server: name] = s = start(root)
      booted(s)

      File.write!(Path.join(dir, "b.ex"), source(b, :one))
      assert {:ok, _} = Patches.load("p", s)
      {:ok, _} = Patches.load("q", s)
      {:ok, _} = Patches.unload("q", s)
      restart(name)

      assert [%{name: "p", loaded?: true, modules: modules}, %{name: "q", loaded?: false}] =
               Patches.list(s)

      assert Enum.sort(modules) == Enum.sort([a, b])
      assert {:ok, _} = Patches.unload("p", s)
      assert :code.is_loaded(b) == false
    end

    test "a source that cannot be read defines nothing", %{root: root, n: n} do
      s = start(root)
      m = mod(n)
      dir = patch(root, "p", [{"m.ex", source(m, :one)}])
      File.mkdir_p!(Path.join(dir, "z.ex"))
      assert [%{modules: [^m]}] = Patches.list(s)
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
  end

  describe "boot_load" do
    test "loads only enabled patches, each on its own", %{root: root, n: n} do
      s = start(root)
      on = mod(n, "On")
      off = mod(n, "Off")
      patch(root, "a_broken", [{"x.ex", "defmodule"}], enabled: true)
      patch(root, "b_on", [{"m.ex", source(on, :on)}], enabled: true)
      patch(root, "c_off", [{"m.ex", source(off, :off)}])

      assert %{"a_broken" => {:error, {:compile, "x.ex", _}}, "b_on" => :ok} =
               results = booted(s)

      assert map_size(results) == 2
      assert on.marker() == :on
      refute Code.ensure_loaded?(off)
      assert [%{loaded?: false}, %{loaded?: true, modules: [^on]}, _off] = Patches.list(s)

      assert %{"patches" => ["a_broken", "b_on"], "good" => false, "loaded_at" => _} =
               written = boot(root)

      assert %{"b_on" => "ok", "a_broken" => "{:error, {:compile" <> _} = written["results"]
      assert Patches.boot_load(s) == {:ok, :started}
      assert Patches.boot_status(s) == {:done, results}
    end

    test "arms .boot before the first load", %{root: root, n: n} do
      s = start(root)
      path = Path.join(root, ".boot")
      report = "send(#{pid_literal()}, {:armed, File.read!(#{inspect(path)})})"
      patch(root, "p", [{"m.ex", hook(mod(n), report)}], enabled: true)

      assert %{"p" => :ok} = booted(s)
      assert_received {:armed, body}
      assert %{"patches" => ["p"], "good" => false} = Jason.decode!(body)
    end

    test "loads nothing when .boot cannot be armed", %{root: root, n: n} do
      m = mod(n)
      patch(root, "p", [{"m.ex", source(m, :one)}], enabled: true)
      File.chmod!(root, 0o555)
      s = start(root)

      assert {:ok, :started} = Patches.boot_load(s)
      assert {:done, %{"p" => {:error, {:arm, _reason}}}} = Patches.boot_status(s)
      refute Code.ensure_loaded?(m)
      assert File.ls!(root) == ["p"]
    end

    test "load and unload wait for the boot load", %{root: root, n: n} do
      m = mod(n)
      held = "send(#{pid_literal()}, {:compiling, self()})\n  receive(do: (:go -> :ok))"
      patch(root, "a_held", [{"m.ex", hook(mod(n, "Held"), held)}], enabled: true)
      patch(root, "b", [{"m.ex", source(m, :one)}])
      s = start(root)

      assert {:ok, :started} = Patches.boot_load(s)
      assert_receive {:compiling, compiler}, 1_000
      assert Patches.load("b", s) == {:error, :boot_loading}
      assert Patches.unload("b", s) == {:error, :boot_loading}
      refute Code.ensure_loaded?(m)

      send(compiler, :go)
      eventually(fn -> match?({:done, _}, Patches.boot_status(s)) end)
      assert Patches.load("b", s) == {:ok, [m]}
    end

    test "runs under the task supervisor", %{root: root, n: n} do
      sup = :"patches_tasks_#{n}"
      start_supervised!({Task.Supervisor, name: sup})
      held = "send(#{pid_literal()}, {:compiling, self()})\n  receive(do: (:go -> :ok))"
      patch(root, "p", [{"m.ex", hook(mod(n), held)}], enabled: true)
      s = start(root, task_supervisor: sup)

      assert {:ok, :started} = Patches.boot_load(s)
      assert_receive {:compiling, compiler}, 1_000
      assert [_task] = Task.Supervisor.children(sup)

      send(compiler, :go)
      eventually(fn -> match?({:done, _}, Patches.boot_status(s)) end)
    end

    test "a later patch is refused over old code an earlier one left", %{root: root, n: n} do
      proto = mod(n, "Proto")
      impl = Module.concat(proto, Integer)
      wait = "send(#{pid_literal()}, {:entered, self()}) && receive(do: (:stop -> :ok))"

      impl_src = fn v ->
        "defimpl #{inspect(proto)}, for: Integer do\n  def a(_), do: #{v} && #{wait}\nend\n"
      end

      # The release's version, which a process is running.
      Code.compile_string("defprotocol #{inspect(proto)} do\n  def a(x)\nend\n" <> impl_src.(0))
      {holder, _ref} = spawn_monitor(fn -> proto.a(1) end)
      assert_receive {:entered, ^holder}

      patch(root, "a", [{"b.ex", impl_src.(1)}], enabled: true)
      patch(root, "b", [{"b.ex", impl_src.(2)}], enabled: true)

      assert %{"a" => :ok, "b" => {:error, {:in_use, [^impl]}}} = booted(start(root))
      assert Process.alive?(holder)
      send(holder, :stop)
    end

    test "a compile past its bound times out alone", %{root: root, n: n} do
      # The hang never ends, so any bound trips it; 5 s leaves a real compile
      # room on a loaded runner.
      s = start(root, compile_timeout_ms: 5_000)
      ok = mod(n, "Ok")

      patch(root, "a_hangs", [{"m.ex", hook(mod(n, "Hangs"), "Process.sleep(:infinity)")}],
        enabled: true
      )

      patch(root, "b_ok", [{"m.ex", source(ok, :ok)}], enabled: true)

      assert %{"a_hangs" => {:error, :timeout}, "b_ok" => :ok} = booted(s, 6_000)
      assert ok.marker() == :ok
    end

    test "no enabled patches is good at once, whatever came before", %{root: root} do
      bad_boot(root)
      s = start(root)
      assert Patches.boot_load(s) == {:ok, :started}
      assert Patches.boot_status(s) == {:done, %{}}
      assert %{"patches" => [], "good" => true} = boot(root)
      refute File.exists?(Path.join(root, ".skipped"))
    end

    test "a previous boot marked good loads", %{root: root, n: n} do
      m = mod(n)
      patch(root, "p", [{"m.ex", source(m, :one)}], enabled: true)
      File.write!(Path.join(root, ".boot"), Jason.encode!(%{"good" => true, "patches" => ["p"]}))
      assert %{"p" => :ok} = booted(start(root))
    end

    test "the breaker skips once, and a later good boot clears the record", %{root: root, n: n} do
      m = mod(n)
      patch(root, "p", [{"m.ex", source(m, :one)}], enabled: true)
      previous = bad_boot(root)

      s = start(root)
      assert Patches.status(s) == %{boot: previous, skipped: nil, running?: false}
      assert Patches.boot_load(s) == {:ok, :skipped}
      assert Patches.boot_load(s) == {:ok, :skipped}
      assert Patches.boot_status(s) == {:skipped, "previous boot not marked good"}
      refute Code.ensure_loaded?(m)

      assert %{
               boot: %{"patches" => [], "good" => true},
               skipped: %{"reason" => "previous boot not marked good", "previous" => ^previous},
               running?: false
             } = Patches.status(s)

      new_vm_boot(root)
      s = start(root)
      assert %{"p" => :ok} = booted(s)
      assert m.marker() == :one
      assert %{skipped: %{}} = Patches.status(s)
      assert Patches.mark_good(s) == :ok
      assert %{boot: %{"good" => true, "patches" => ["p"]}, skipped: nil} = Patches.status(s)
    end

    test "the breaker trips on a .boot it cannot read", %{root: root, n: n} do
      patch(root, "p", [{"m.ex", source(mod(n), :one)}], enabled: true)
      File.write!(Path.join(root, ".boot"), "{not json")
      assert Patches.boot_load(start(root)) == {:ok, :skipped}

      new_vm_boot(root)
      File.rm!(Path.join(root, ".boot"))
      File.mkdir_p!(Path.join([root, ".boot", "x"]))
      s = start(root)
      assert Patches.boot_load(s) == {:ok, :skipped}
      assert %{"previous" => %{"unreadable" => ":eisdir"}} = Patches.status(s).skipped
      # The write that could not replace the directory left no temp file.
      refute File.exists?(Path.join(root, ".boot.tmp"))
    end

    test "survives a restart of the server without loading twice", %{root: root, n: n} do
      flag = :atomics.new(1, [])
      patch(root, "p", [{"m.ex", source(mod(n), :one)}], enabled: true)

      [server: name] =
        s = start(root, boot_complete?: fn -> :atomics.get(flag, 1) == 1 end, good_after_ms: 0)

      results = booted(s)
      restart(name)

      assert Patches.boot_load(s) == {:ok, :started}
      assert Patches.boot_status(s) == {:done, results}
      assert %{"good" => false} = boot(root)

      :atomics.put(flag, 1, 1)
      eventually(fn -> boot(root)["good"] == true end)
    end
  end

  describe "marking the boot good" do
    test "mark_good flips the record", %{root: root, n: n} do
      s = start(root)
      patch(root, "p", [{"m.ex", source(mod(n), :one)}], enabled: true)
      assert Patches.mark_good(s) == {:error, :no_boot}
      booted(s)
      assert Patches.mark_good(s) == :ok
      assert %{"good" => true, "patches" => ["p"]} = boot(root)
    end

    test "once the boot completed and the delay passed", %{root: root, n: n} do
      patch(root, "p", [{"m.ex", source(mod(n), :one)}], enabled: true)
      s = start(root, boot_complete?: fn -> true end, good_after_ms: 10)
      booted(s)
      eventually(fn -> boot(root)["good"] == true end)
    end

    test "not before the delay, even with the boot complete", %{root: root, n: n} do
      patch(root, "p", [{"m.ex", source(mod(n), :one)}], enabled: true)
      [server: name] = s = start(root, boot_complete?: fn -> true end, good_after_ms: 60_000)
      booted(s)
      for _ <- 1..5, do: send(name, :check_good)
      Patches.list(s)
      assert %{"good" => false} = boot(root)
    end

    test "not while the boot has not completed", %{root: root, n: n} do
      test_pid = self()
      patch(root, "p", [{"m.ex", source(mod(n), :one)}], enabled: true)

      s =
        start(root,
          boot_complete?: fn -> send(test_pid, :asked) && false end,
          good_after_ms: 0
        )

      booted(s)
      assert_receive :asked, 1_000
      assert_receive :asked, 1_000
      assert %{"good" => false} = boot(root)
    end

    test "an orchestrator that exits counts as not complete", %{root: root, n: n} do
      test_pid = self()
      patch(root, "p", [{"m.ex", source(mod(n), :one)}], enabled: true)

      [server: name] =
        s =
        start(root,
          boot_complete?: fn -> send(test_pid, :asked) && exit(:noproc) end,
          good_after_ms: 0
        )

      pid = GenServer.whereis(name)
      booted(s)
      assert_receive :asked, 1_000
      assert_receive :asked, 1_000
      assert GenServer.whereis(name) == pid
    end

    test "a failed write is retried, never taken for success", %{root: root, n: n} do
      flag = :atomics.new(1, [])
      patch(root, "p", [{"m.ex", source(mod(n), :one)}], enabled: true)
      s = start(root, boot_complete?: fn -> :atomics.get(flag, 1) == 1 end, good_after_ms: 0)
      booted(s)

      File.chmod!(root, 0o555)
      :atomics.put(flag, 1, 1)
      Process.sleep(50)
      assert %{"good" => false} = boot(root)

      File.chmod!(root, 0o755)
      eventually(fn -> boot(root)["good"] == true end)
    end

    test "a stop before the latch leaves the boot unmarked", %{root: root, n: n} do
      patch(root, "p", [{"m.ex", source(mod(n), :one)}], enabled: true)
      [server: name] = s = start(root, boot_complete?: fn -> true end, good_after_ms: 60_000)
      booted(s)

      # What a supervisor that gave up on crashing children sends.
      stop_supervised!(name)
      assert %{"good" => false} = boot(root)
    end

    test "a kill leaves the boot unmarked", %{root: root, n: n} do
      patch(root, "p", [{"m.ex", source(mod(n), :one)}], enabled: true)
      [server: name] = s = start(root, poll_ms: 60_000)
      booted(s)
      Process.exit(GenServer.whereis(name), :kill)
      assert %{"good" => false} = boot(root)
    end

    test "a stop after the boot was marked writes nothing", %{root: root, n: n} do
      patch(root, "p", [{"m.ex", source(mod(n), :one)}], enabled: true)
      [server: name] = s = start(root, boot_complete?: fn -> true end, good_after_ms: 0)
      booted(s)
      eventually(fn -> boot(root)["good"] == true end)

      File.rm!(Path.join(root, ".boot"))
      stop_supervised!(name)
      refute File.exists?(Path.join(root, ".boot"))
    end
  end

  test "an absent server answers an error, never an exit" do
    s = [server: :"absent_#{System.unique_integer([:positive])}"]
    assert Patches.list(s) == {:error, :not_running}
    assert Patches.load("p", s) == {:error, :not_running}
    assert Patches.boot_load(s) == {:error, :not_running}
    assert Patches.boot_status(s) == {:error, :not_running}
    assert Patches.status(s) == {:error, :not_running}
    assert Patches.mark_good(s) == {:error, :not_running}
  end

  test "off the flavor it does not start" do
    assert Patches.start_link(enabled: false) == :ignore
  end
end
