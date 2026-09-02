defmodule Vagus.Platform.PressureTest do
  use ExUnit.Case, async: true

  alias Vagus.Platform.Pressure

  # Verbatim /proc/pressure/memory from an idle Linux host.
  @idle """
  some avg10=0.00 avg60=0.00 avg300=0.00 total=2383
  full avg10=0.00 avg60=0.00 avg300=0.00 total=250
  """

  @under_pressure """
  some avg10=1.23 avg60=12.50 avg300=4.07 total=987654321
  full avg10=0.41 avg60=6.75 avg300=1.02 total=123456
  """

  defp fixture(contents) do
    path = Path.join(System.tmp_dir!(), "vagus_psi_#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "parses an idle /proc/pressure/memory" do
    assert Pressure.memory(fixture(@idle)) ==
             {:ok,
              %{
                some: %{avg10: 0.0, avg60: 0.0, avg300: 0.0, total: 2383},
                full: %{avg10: 0.0, avg60: 0.0, avg300: 0.0, total: 250}
              }}
  end

  test "parses non-zero averages as floats" do
    assert {:ok, %{some: some, full: full}} = Pressure.memory(fixture(@under_pressure))
    assert some == %{avg10: 1.23, avg60: 12.5, avg300: 4.07, total: 987_654_321}
    assert full == %{avg10: 0.41, avg60: 6.75, avg300: 1.02, total: 123_456}
  end

  test "line order does not matter" do
    contents = """
    full avg10=0.10 avg60=0.20 avg300=0.30 total=7
    some avg10=1.00 avg60=2.00 avg300=3.00 total=9
    """

    assert {:ok, %{some: %{avg10: 1.0, total: 9}, full: %{avg10: 0.1, total: 7}}} =
             Pressure.memory(fixture(contents))
  end

  test "a missing file is :error, not a raise" do
    assert :error = Pressure.memory(Path.join(System.tmp_dir!(), "vagus_no_such_psi"))
  end

  test "an empty file is :error" do
    assert :error = Pressure.memory(fixture(""))
  end

  test "a file with only a some line is :error" do
    assert :error = Pressure.memory(fixture("some avg10=0.00 avg60=0.00 avg300=0.00 total=1\n"))
  end

  test "a file with only a full line is :error" do
    assert :error = Pressure.memory(fixture("full avg10=0.00 avg60=0.00 avg300=0.00 total=1\n"))
  end

  for {label, contents} <- [
        {"free text", "not pressure information at all\n"},
        {"a missing avg300", "some avg10=0.00 avg60=0.00 total=1\nfull avg10=0.00 total=2\n"},
        {"a truncated line", "some avg10=0.00 avg60=0.00 avg300=\nfull avg10=0.00 total=2\n"},
        {"a non-numeric average",
         "some avg10=high avg60=0.00 avg300=0.00 total=1\n" <>
           "full avg10=0.00 avg60=0.00 avg300=0.00 total=2\n"},
        {"a non-integer total",
         "some avg10=0.00 avg60=0.00 avg300=0.00 total=1.5\n" <>
           "full avg10=0.00 avg60=0.00 avg300=0.00 total=2\n"},
        {"a negative average",
         "some avg10=-1.00 avg60=0.00 avg300=0.00 total=1\n" <>
           "full avg10=0.00 avg60=0.00 avg300=0.00 total=2\n"},
        {"an average with trailing junk",
         "some avg10=0.00% avg60=0.00 avg300=0.00 total=1\n" <>
           "full avg10=0.00 avg60=0.00 avg300=0.00 total=2\n"},
        {"a bare keyword", "some\nfull\n"}
      ] do
    test "#{label} is :error" do
      assert :error = Pressure.memory(fixture(unquote(contents)))
    end
  end

  test "reads the real /proc/pressure/memory when the kernel has PSI" do
    # Guards the format assumption against a live kernel. Absent on every
    # board's kernel today, hence the existence check rather than a skip tag.
    if File.exists?("/proc/pressure/memory") do
      assert {:ok, %{some: some, full: full}} = Pressure.memory()
      assert is_float(some.avg10) and is_integer(some.total)
      assert is_float(full.avg10) and is_integer(full.total)
    end
  end
end
