defmodule Vagus.SSHAccess.Keypair do
  @moduledoc """
  The device's SSH access keypair held in `Vagus.SSHAccess` state.

  Carries a custom `Inspect` implementation that redacts the private key, so
  an accidental `inspect/1` (e.g. into a log line or an IEx session) can't
  leak the secret. Note this does not cover a raw `erl_crash.dump`, which
  prints terms without the protocol.
  """

  @enforce_keys [:public_key, :private_key, :fingerprint]
  defstruct [:public_key, :private_key, :fingerprint]

  @type t :: %__MODULE__{
          public_key: String.t(),
          private_key: String.t(),
          fingerprint: String.t()
        }

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(keypair, _opts) do
      concat([
        "#",
        inspect(keypair.__struct__),
        "<",
        to_string(keypair.fingerprint),
        " private_key=[REDACTED]>"
      ])
    end
  end
end
