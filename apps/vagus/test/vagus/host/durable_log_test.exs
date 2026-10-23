defmodule Vagus.Host.DurableLogTest do
  # async: false — the handler under test is registered with the global :logger.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Vagus.Host.DurableLog

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: tmp_dir} do
    prev = Application.get_env(:vagus, :durable_log)
    Application.put_env(:vagus, :durable_log, dir: tmp_dir)

    on_exit(fn ->
      _ = :logger.remove_handler(:vagus_durable)

      if prev,
        do: Application.put_env(:vagus, :durable_log, prev),
        else: Application.delete_env(:vagus, :durable_log)
    end)

    :ok
  end

  defp sync, do: :ok = :logger_std_h.filesync(:vagus_durable)

  test "writes one timestamped line per event with the module", %{tmp_dir: tmp_dir} do
    start_supervised!(DurableLog)

    Logger.info("durable hello")
    sync()

    assert DurableLog.path() == Path.join(tmp_dir, "vagus.log")
    contents = File.read!(DurableLog.path())

    assert contents =~
             ~r/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z \[info\] module=Vagus\.Host\.DurableLogTest durable hello$/m

    assert {:ok, [last]} = DurableLog.tail(1)
    assert last =~ "durable hello"
  end

  test "drops events below the configured level" do
    start_supervised!(DurableLog)

    Logger.debug("durable too quiet")
    Logger.info("durable loud enough")
    sync()

    contents = File.read!(DurableLog.path())
    refute contents =~ "durable too quiet"
    assert contents =~ "durable loud enough"
  end

  test "rotates into gzipped numbered files at the cap", %{tmp_dir: tmp_dir} do
    start_supervised!({DurableLog, max_no_bytes: 200, max_no_files: 2})

    for i <- 1..20, do: Logger.info("durable rotation line #{i}")
    sync()

    assert tmp_dir |> File.ls!() |> Enum.sort() == [
             "vagus.log",
             "vagus.log.0.gz",
             "vagus.log.1.gz"
           ]

    assert :zlib.gunzip(File.read!(Path.join(tmp_dir, "vagus.log.0.gz"))) =~
             "durable rotation line"
  end

  test "an unwritable dir is :ignore with one warning", %{tmp_dir: tmp_dir} do
    # Under a regular file, so mkdir fails even when the suite runs as root.
    blocker = Path.join(tmp_dir, "not_a_dir")
    File.write!(blocker, "")
    Application.put_env(:vagus, :durable_log, dir: Path.join(blocker, "log"))

    log =
      capture_log(fn ->
        assert DurableLog.start_link([]) == :ignore
      end)

    assert length(Regex.scan(~r/durable log disabled/, log)) == 1
    assert {:error, {:not_found, :vagus_durable}} = :logger.get_handler_config(:vagus_durable)
  end

  test "unset or false config is :ignore and adds no handler" do
    Application.delete_env(:vagus, :durable_log)
    assert DurableLog.start_link([]) == :ignore

    Application.put_env(:vagus, :durable_log, false)
    assert DurableLog.start_link([]) == :ignore

    assert {:error, {:not_found, :vagus_durable}} = :logger.get_handler_config(:vagus_durable)
  end

  test "true config means the defaults" do
    Application.put_env(:vagus, :durable_log, true)
    assert DurableLog.path() == "/data/vagus/log/vagus.log"
  end

  test "syncs to disk every second" do
    start_supervised!(DurableLog)
    {:ok, %{config: config}} = :logger.get_handler_config(:vagus_durable)
    assert config.filesync_repeat_interval == 1_000
  end

  test "terminate removes the handler" do
    start_supervised!(DurableLog)
    assert {:ok, _} = :logger.get_handler_config(:vagus_durable)

    stop_supervised!(DurableLog)

    assert {:error, {:not_found, :vagus_durable}} = :logger.get_handler_config(:vagus_durable)
  end

  test "a handler left by a killed owner is taken over with this config", %{tmp_dir: tmp_dir} do
    Application.put_env(:vagus, :durable_log, dir: tmp_dir, level: :warning)
    pid = start_supervised!(DurableLog, restart: :temporary)
    Process.exit(pid, :kill)
    assert {:ok, %{level: :warning}} = :logger.get_handler_config(:vagus_durable)

    Application.put_env(:vagus, :durable_log, dir: tmp_dir)
    start_supervised!({DurableLog, name: :durable_log_second_owner}, id: :second)
    assert {:ok, %{level: :info}} = :logger.get_handler_config(:vagus_durable)

    Logger.info("durable after take-over")
    sync()
    assert File.read!(DurableLog.path()) =~ "durable after take-over"
  end

  test "a left handler writing elsewhere is replaced", %{tmp_dir: tmp_dir} do
    Application.put_env(:vagus, :durable_log, dir: Path.join(tmp_dir, "old"))
    pid = start_supervised!(DurableLog, restart: :temporary)
    Process.exit(pid, :kill)

    Application.put_env(:vagus, :durable_log, dir: tmp_dir)
    start_supervised!({DurableLog, name: :durable_log_second_owner}, id: :second)

    {:ok, %{config: config}} = :logger.get_handler_config(:vagus_durable)
    assert config.file == String.to_charlist(Path.join(tmp_dir, "vagus.log"))
  end
end
