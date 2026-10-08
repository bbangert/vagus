defmodule Vagus.App.BootTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.App.{Boot, Controller, Facts}
  alias Vagus.App.Spec.Schema
  alias Vagus.Resource.{Store, TestInstance}
  alias Vagus.Test.AppManifests

  @auto "only_host_uts"
  @manual "elixir_probe"
  @once "local_once"
  @core "homeassistant"

  # A store that has the App kind and nothing that acts on it.
  setup do
    instance =
      TestInstance.start!(
        kinds: %{
          app: [
            finalizers: [:app],
            validators: [&Controller.validate/1],
            encode_spec: &Schema.encode_spec/1,
            decode_spec: &Schema.decode_spec/1
          ]
        }
      )

    i = [instance: instance]
    facts = Facts.read(data_root: "/nowhere")

    for slug <- [@auto, @manual, @once] do
      spec = Schema.from_manifest(AppManifests.get(slug), facts, %{run: true})
      {:ok, _app} = Store.create(:app, slug, spec, i)
    end

    {:ok, _core} = Store.create(:app, @core, %{lifecycle: :core, version: "2026.8.0"}, i)

    dir =
      Path.join(
        System.tmp_dir!(),
        "vagus-boot-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)

    %{
      i: i,
      opts: i ++ [marker: Path.join(dir, "run.booted")],
      marker: Path.join(dir, "run.booted")
    }
  end

  defp runs(i), do: Map.new(Store.list(:app, i), &{&1.name, &1.spec.run})
  defp generations(i), do: Map.new(Store.list(:app, i), &{&1.name, &1.generation})
  defp pending(marker, seen), do: write(marker, %{"state" => "pending", "apps" => seen})

  defp write(marker, content) do
    File.mkdir_p!(Path.dirname(marker))
    File.write!(marker, Jason.encode!(content))
  end

  defp seen(i), do: Map.new(Store.list(:app, i), &{&1.name, [&1.uid, &1.generation]})

  @booted %{@auto => true, @manual => false, @once => false, @core => true}

  test "run_after_boot/1 follows the profile's boot, and a run-once app does not run" do
    facts = Facts.read(data_root: "/nowhere")

    of = fn slug, fields ->
      {:ok, spec} =
        Schema.validate(Schema.from_manifest(AppManifests.get(slug), facts, fields), facts)

      spec
    end

    assert Boot.run_after_boot(%{lifecycle: :core}) == true
    assert Boot.run_after_boot(of.(@auto, %{})) == nil
    assert Boot.run_after_boot(of.(@auto, %{settings: %{boot: "manual"}})) == false
    assert Boot.run_after_boot(of.(@manual, %{})) == false
    assert Boot.run_after_boot(of.(@manual, %{settings: %{boot: "auto"}})) == nil
    assert Boot.run_after_boot(of.(@once, %{})) == false
    # Whatever its boot says: `local_once` is also started by hand only.
    once = of.(@auto, %{})
    assert Boot.run_after_boot(put_in(once.config.startup, "once")) == false
    assert Boot.run_after_boot(of.("core_mqtt", %{})) == nil
  end

  test "the first start of a boot sets every app, in one commit, and says so", ctx do
    before = generations(ctx.i)
    assert Boot.normalise(ctx.opts) == :done
    assert runs(ctx.i) == @booted
    assert Jason.decode!(File.read!(ctx.marker)) == %{"state" => "done"}
    # Only what had to change was written.
    assert generations(ctx.i)[@auto] == before[@auto]
    assert generations(ctx.i)[@manual] == before[@manual] + 1
  end

  test "a later start of the same boot changes nothing a user has chosen since", ctx do
    assert Boot.normalise(ctx.opts) == :done
    {:ok, _app} = Store.update_spec(:app, @manual, %{run: true}, ctx.i)
    {:ok, _app} = Store.update_spec(:app, @core, %{run: false}, ctx.i)

    assert Boot.normalise(ctx.opts) == :already
    assert runs(ctx.i) == %{@booted | @manual => true, @core => false}
  end

  test "cut before the commit: the next start makes it", ctx do
    pending(ctx.marker, seen(ctx.i))
    assert Boot.normalise(ctx.opts) == :done
    assert runs(ctx.i) == @booted
    assert Jason.decode!(File.read!(ctx.marker)) == %{"state" => "done"}
  end

  test "a store that cannot be asked: the start goes on, the marker stays short of done, " <>
         "and the next start of the boot finishes",
       ctx do
    before = runs(ctx.i)
    name = Store.name(ctx.i[:instance])
    store = Process.whereis(name)

    # Nobody answers to the store's name: a call to it exits, as one does
    # whose store stopped over a write or did not answer in time.
    Process.unregister(name)
    log = capture_log(fn -> assert Boot.normalise(ctx.opts) == :done end)
    Process.register(store, name)

    assert log =~ "apps were not set for this boot"
    assert %{"state" => "pending"} = Jason.decode!(File.read!(ctx.marker))
    assert runs(ctx.i) == before

    assert Boot.normalise(ctx.opts) == :done
    assert runs(ctx.i) == @booted
    assert Jason.decode!(File.read!(ctx.marker)) == %{"state" => "done"}
  end

  test "cut before the commit, a user having written meanwhile: that app is left as they set it",
       ctx do
    pending(ctx.marker, seen(ctx.i))
    {:ok, _app} = Store.update_spec(:app, @once, %{options: %{}, run: true}, ctx.i)
    {:ok, _app} = Store.update_spec(:app, @once, [{:inc, [:start_counter]}], ctx.i)

    assert Boot.normalise(ctx.opts) == :done
    assert runs(ctx.i) == %{@booted | @once => true}
  end

  test "cut after the commit: the next start undoes nothing, the user's later choice least of all",
       ctx do
    recorded = seen(ctx.i)
    assert Boot.normalise(ctx.opts) == :done
    {:ok, _app} = Store.update_spec(:app, @manual, %{run: true}, ctx.i)
    after_commit = generations(ctx.i)
    # As a start cut between its commit and its second write of the marker
    # left things.
    pending(ctx.marker, recorded)

    assert Boot.normalise(ctx.opts) == :done
    assert runs(ctx.i) == %{@booted | @manual => true}
    assert generations(ctx.i) == after_commit
  end

  test "an app installed after the marker was written is left alone", ctx do
    pending(ctx.marker, Map.delete(seen(ctx.i), @manual))
    assert Boot.normalise(ctx.opts) == :done
    assert runs(ctx.i) == %{@booted | @manual => true}
  end

  test "an app being removed is not written to, and does not keep the others from being set",
       ctx do
    {:ok, %{deleting?: true}} = Store.delete(:app, @manual, ctx.i)
    assert Boot.normalise(ctx.opts) == :done
    assert runs(ctx.i) == %{@booted | @manual => true}
  end

  test "without a run directory every start is taken for a boot", ctx do
    assert Boot.normalise(ctx.i ++ [marker: nil]) == :done
    {:ok, _app} = Store.update_spec(:app, @manual, %{run: true}, ctx.i)
    assert Boot.normalise(ctx.i ++ [marker: nil]) == :done
    assert runs(ctx.i) == @booted
  end

  test "a marker that cannot be read is taken for done", ctx do
    File.mkdir_p!(Path.dirname(ctx.marker))
    File.write!(ctx.marker, "{\"state\":\"pend")
    assert Boot.normalise(ctx.opts) == :already
    assert runs(ctx.i)[@manual] == true
  end

  test "a marker that cannot be written is logged, and the apps are set all the same", ctx do
    File.mkdir_p!(Path.dirname(ctx.marker))
    # A directory where the marker's temporary file would go.
    File.mkdir_p!(ctx.marker <> ".tmp")

    log = capture_log(fn -> assert Boot.normalise(ctx.opts) == :done end)
    assert log =~ "was not written"
    assert runs(ctx.i) == @booted
  end

  test "the default marker is beside the run directory, which is emptied at every start" do
    dir = Application.get_env(:vagus, :run_state_dir)
    assert Boot.marker() == dir <> ".booted"
    refute String.starts_with?(Boot.marker(), dir <> "/")
  end

  test "as a child it does the work in its start, leaves no process, and is done when that returns",
       ctx do
    spec = Boot.child_spec(ctx.opts)
    {:ok, supervisor} = Supervisor.start_link([spec], strategy: :one_for_one)
    assert runs(ctx.i) == @booted
    assert [{Boot, :undefined, :worker, _modules}] = Supervisor.which_children(supervisor)
    Supervisor.stop(supervisor)
  end
end
