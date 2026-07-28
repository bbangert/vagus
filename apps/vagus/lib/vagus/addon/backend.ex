defmodule Vagus.Addon.Backend do
  @moduledoc """
  The runtime backend behaviour for add-ons — the `:container | :native |
  :microvm` seam the `docs/contract-2026.7-m4-addendum.md` §A1.6 requires from
  day one so the add-on manager (`Vagus.Addon`, P3) stays runtime-agnostic.

  A backend receives a runtime-neutral `Vagus.Addon.Backend.Spec` (built by the
  manager from the add-on's config + the pinned run params) and drives the
  container/service lifecycle. Only `Vagus.Addon.Backend.Container` is
  implemented in M4; `Native` (BEAM-subtree add-ons, e.g. the mqttx broker)
  and `Microvm` are declared stubs that raise, keeping the seam honest and
  additive.

  Ids are backend-opaque strings (a container id/name for `Container`).
  """

  alias Vagus.Addon.Backend.Spec

  @typedoc "Backend-opaque handle for a started add-on (container id/name for Container)."
  @type id :: String.t()

  @typedoc "Coarse runtime state, normalized across backends."
  @type state :: :running | :stopped | :restarting | :unknown

  @doc "Ensure the add-on's image/artifact is present locally."
  @callback pull(Spec.t()) :: :ok | {:error, term()}

  @doc "Create the add-on's container/instance from `spec`; return its id."
  @callback create(Spec.t()) :: {:ok, id()} | {:error, term()}

  @doc "Start a created add-on. Idempotent (already-running is `:ok`)."
  @callback start(id()) :: :ok | {:error, term()}

  @doc "Stop a running add-on (`opts[:timeout]` seconds). Idempotent."
  @callback stop(id(), keyword()) :: :ok | {:error, term()}

  @doc "Remove an add-on's container/instance. Idempotent (missing is `:ok`)."
  @callback remove(id(), keyword()) :: :ok | {:error, term()}

  @doc "Coarse current state of the add-on."
  @callback state(id()) :: {:ok, state()} | {:error, term()}

  @doc """
  Removes an image by ref, once nothing needs it — `Vagus.Addon.Update` calls
  this after a successful update so the superseded image doesn't sit on the
  data partition forever.

  Best-effort by contract: an image still referenced by another container is
  expected to fail, and the caller treats that as normal rather than as an
  update failure. Backends with no image concept (`Native`) return `:ok`.
  """
  @callback remove_image(image :: String.t(), opts :: keyword()) :: :ok | {:error, term()}
end
