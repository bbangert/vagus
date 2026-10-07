defmodule Vagus.App.Backend do
  @moduledoc """
  What runs an app, as a controller needs it: what exists now (`observe/2`),
  and one change at a time.

  Every action is idempotent against observation. It asks for an end state
  and succeeds when that state already holds, so a pass that repeats an
  action after a crash carries on: `start` of a running instance, `stop` of
  one that is stopped or gone, and `remove` of one that is gone are `:ok`.
  `create` is the exception a caller must see, because the instance that
  exists under the name was not made from its config: `{:error,
  :already_exists}`.

  An action does one engine call's worth of work. Pulling an image is not
  one of them: it takes minutes and belongs to `Vagus.App.Pulls`.

  ## What cannot be observed

  With the engine away `observe/2` and `image_present?/2` return
  `{:unavailable, :engine_unavailable}`, the value
  `c:Vagus.Resource.Controller.observe/2` passes on. It is never reported as
  `:absent`, which a controller would answer by creating everything again
  while the engine starts. Any other failure to read is `{:error, failure}`.

  ## Errors

  `{:error, t:Vagus.Runtime.Docker.failure/0}`, with the engine's own message
  where it gave one. Which of them is worth a retry is for the caller.

  ## Options

  Every function takes the options its implementation documents; a caller
  holds them as data and passes them unchanged.
  """

  alias Vagus.Runtime.Docker

  @typedoc "What the instance is called: a container name, or a native app's slug."
  @type name :: String.t()

  @typedoc """
  One instance as it is now.

    * `id` changes whenever the instance is made anew.
    * `exit_code` is the last exit's, and only until the next start.
    * `started_at` is the engine's own text, on the engine's clock: compare
      it for equality only. `nil` before the first start.
    * `restart_count` counts restarts by the engine's restart policy alone.
    * `health` is `:none` without a healthcheck.
    * `env` holds the app's token. Do not log an instance.
    * `address` is the instance's address on the app network, `nil` on the
      host network and while it is not running.
  """
  @type instance :: %{
          id: String.t(),
          state: :created | :running | :exited | :dead | :restarting | :paused | :removing,
          exit_code: integer() | nil,
          started_at: String.t() | nil,
          restart_count: non_neg_integer(),
          health: :none | :starting | :healthy | :unhealthy,
          health_failing_streak: non_neg_integer(),
          image: String.t() | nil,
          image_id: String.t() | nil,
          labels: %{optional(String.t()) => String.t()},
          env: %{optional(String.t()) => String.t()},
          address: String.t() | nil
        }

  @type unavailable :: {:unavailable, atom()}
  @type error :: {:error, Docker.failure()}
  @type action :: :create | :start | :stop | :remove | :remove_image

  @callback observe(name(), keyword()) :: {:ok, :absent | instance()} | unavailable() | error()

  @callback image_present?(image :: String.t(), keyword()) ::
              {:ok, boolean()} | unavailable() | error()

  @doc "Makes the instance from `config`, the backend's own description of it, without starting it."
  @callback create(name(), config :: map(), keyword()) ::
              {:ok, id :: String.t()} | {:error, :already_exists} | error()

  @callback start(name(), keyword()) :: :ok | error()

  @doc "`grace` is the seconds the instance gets to stop by itself; `nil` is the backend's default."
  @callback stop(name(), grace :: non_neg_integer() | nil, keyword()) :: :ok | error()

  @callback remove(name(), keyword()) :: :ok | error()

  @callback remove_image(image :: String.t(), keyword()) :: :ok | error()

  @doc "The `Vagus.Resource.Lanes` class an action runs under, or `nil` for none."
  @callback lane(action()) :: Vagus.Resource.Lanes.class() | nil
end
