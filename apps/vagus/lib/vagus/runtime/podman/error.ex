defmodule Vagus.Runtime.Podman.Error do
  @moduledoc """
  Maps a failed `podman` call onto `Vagus.Runtime.Engine`'s closed error
  set. Exit codes first (podman 6.1.4: 125 generic; 1 absent for `rm` and
  the `exists` verbs; 2 in use for `rmi`), then the stable sentinel texts
  podman wraps its errors around, matched as substrings so a longer chain
  still matches. Every text here is pinned against output recorded from a
  real podman (`test/fixtures/podman/cli_results.txt`); re-record on every
  podman bump.
  """

  alias Vagus.Runtime.Engine

  @detail_bytes 512

  # First match wins; `:any` matches every verb.
  @texts [
    {"no such container", :any, {:error, :not_found}},
    {"image not known", :create, {:error, {:failed, :create, :image_not_found}}},
    {"network not found", :create, {:error, {:failed, :create, :network_not_found}}},
    {"image not known", :any, {:error, :not_found}},
    {"no such image", :any, {:error, :not_found}},
    {"network already exists", :ensure_network, :ok},
    {"already in use", :create, {:error, :conflict}},
    {"image is in use", :any, {:error, :in_use}},
    # SQLite's busy wait gave up; the only lock in podman with a timeout.
    # Not yet seen on a device.
    {"database is locked", :any, {:error, :busy}}
  ]

  @spec classify(atom(), pos_integer(), binary()) :: :ok | {:error, Engine.error()}
  def classify(verb, status, output) do
    by_status(verb, status) || by_text(verb, String.downcase(output)) ||
      {:error, {:failed, verb, detail(output)}}
  end

  # podman itself died on a signal (muontrap reports 128 + signo): the
  # engine went away mid-call. An exec's status is the command's.
  defp by_status(verb, status) when verb != :exec and status in 129..159,
    do: {:error, :unavailable}

  defp by_status(verb, 1) when verb in [:remove, :exists, :remove_image], do: {:error, :not_found}
  defp by_status(:remove_image, 2), do: {:error, :in_use}
  defp by_status(_verb, _status), do: nil

  defp by_text(verb, text) do
    Enum.find_value(@texts, fn {needle, for_verb, result} ->
      if for_verb in [:any, verb] and String.contains?(text, needle), do: result
    end)
  end

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
