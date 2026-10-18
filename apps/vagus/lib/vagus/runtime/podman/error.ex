defmodule Vagus.Runtime.Podman.Error do
  @moduledoc """
  Maps a failed `podman` call onto `Vagus.Runtime.Engine`'s closed error
  set. Exit codes first (podman 6.1.4: 125 generic; 1 absent for the
  `exists` verbs; 2 in use for `rmi`), then the stable sentinel texts
  podman wraps its errors around, matched as substrings so a longer chain
  still matches. Every text here is pinned against output recorded from a
  real podman (`test/fixtures/podman/cli_results.txt`); re-record on every
  podman bump.
  """

  alias Vagus.Runtime.Engine

  @detail_bytes 512

  @removals [:remove, :remove_image]

  # `rm` and `rmi` always run with `--ignore`, which makes an absent target
  # exit 0; their 1 is a real error unless its text names the object as
  # absent. Any other status with such a text is a failure that merely
  # quotes a lookup, e.g. of a dependency.
  @absent %{
    remove: ["no such container"],
    remove_image: ["image not known", "no such image"]
  }

  # First match wins; `:any` matches every verb, `:lookup` every verb but
  # the removals, whose absence is read from `@absent` alone.
  @texts [
    {"no such container", :lookup, {:error, :not_found}},
    {"image not known", :create, {:error, {:failed, :create, :image_not_found}}},
    {"network not found", :create, {:error, {:failed, :create, :network_not_found}}},
    {"image not known", :lookup, {:error, :not_found}},
    {"no such image", :lookup, {:error, :not_found}},
    {"network already exists", :ensure_network, :ok},
    {"already in use", :create, {:error, :conflict}},
    {"image is in use", :any, {:error, :in_use}},
    # SQLite's busy wait gave up; the only lock in podman with a timeout.
    # Not yet seen on a device.
    {"database is locked", :any, {:error, :busy}}
  ]

  @spec classify(atom(), pos_integer(), binary()) :: :ok | {:error, Engine.error()}
  def classify(verb, status, output) do
    text = String.downcase(output)

    by_status(verb, status) || absent(verb, status, text) || by_text(verb, text) ||
      {:error, {:failed, verb, detail(output)}}
  end

  # podman itself died on a signal (muontrap reports 128 + signo): the
  # engine went away mid-call. An exec's status is the command's.
  defp by_status(verb, status) when verb != :exec and status in 129..159,
    do: {:error, :unavailable}

  # `exists` prints nothing, so its status is all there is.
  defp by_status(:exists, 1), do: {:error, :not_found}
  defp by_status(:remove_image, 2), do: {:error, :in_use}
  defp by_status(_verb, _status), do: nil

  defp absent(verb, 1, text) when verb in @removals,
    do: if(String.contains?(text, @absent[verb]), do: {:error, :not_found})

  defp absent(_verb, _status, _text), do: nil

  defp by_text(verb, text) do
    Enum.find_value(@texts, fn {needle, for_verb, result} ->
      if applies?(for_verb, verb) and String.contains?(text, needle), do: result
    end)
  end

  defp applies?(:lookup, verb), do: verb not in @removals
  defp applies?(for_verb, verb), do: for_verb in [:any, verb]

  # Cut at a codepoint boundary: the detail may be logged or JSON-encoded.
  @spec detail(binary()) :: binary()
  def detail(output) do
    output = String.trim(output)
    size = byte_size(output)

    if size > @detail_bytes,
      do: output |> binary_part(size - @detail_bytes, @detail_bytes) |> drop_continuation(),
      else: output
  end

  defp drop_continuation(<<0b10::2, _::6, rest::binary>>), do: drop_continuation(rest)
  defp drop_continuation(bin), do: bin
end
