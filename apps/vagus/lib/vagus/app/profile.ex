defmodule Vagus.App.Profile do
  @moduledoc """
  What kind of thing an app is to run: `spec.lifecycle` names one of three
  profiles, each a module that answers the same questions about an app's
  spec. See the table in `docs/app-lifecycle.md`.

  The answers are not settings. A controller is written against three
  profiles, not against every combination of their answers, and a spec may
  set only the fields its profile lists (`c:fields/0`, `c:settings/0`).

  Every callback is pure and takes the spec as admitted
  (`Vagus.App.Spec.Schema`).
  """

  alias Vagus.App.Profile.{Container, Core, Native}

  @type tag :: :container | :core | :native
  @type spec :: map()

  @typedoc """
  What to do about an instance that ended without being asked to.

    * `:never`: it stays down and the app has failed.
    * `{:restart, budget}`: start it again, `attempts` times with a pause
      that starts at `backoff_ms` and doubles; at most `max_sequences` such
      runs per `sequence_window_ms`. Ready for `reset_after_ms` forgets the
      attempts.
    * `{:crash_loop, rule}`: the engine restarts it. Only `restarts` of them
      within `window_ms` are acted on, by making the instance anew, and that
      at most `max_actions` times per `action_window_ms`.
  """
  @type restart_policy ::
          :never
          | {:restart,
             %{
               attempts: pos_integer(),
               backoff_ms: pos_integer(),
               max_sequences: pos_integer(),
               sequence_window_ms: pos_integer(),
               reset_after_ms: pos_integer()
             }}
          | {:crash_loop,
             %{
               restarts: pos_integer(),
               window_ms: pos_integer(),
               max_actions: pos_integer(),
               action_window_ms: pos_integer()
             }}

  @typedoc """
  `:container` is running, and healthy where the image has a healthcheck;
  `{:http, path}` is an answer from the app itself; `:process` is the
  instance existing. Past `deadline_ms` an app that is not ready has failed.
  """
  @type readiness :: %{
          kind: :container | {:http, String.t()} | :process,
          deadline_ms: pos_integer() | :infinity
        }

  @typedoc """
  Seconds an instance gets to stop by itself: `:default` is the backend's,
  and `{:image_env, name, extra_s}` is the image's environment variable
  `name`, in milliseconds, plus `extra_s`.
  """
  @type stop_grace :: :default | {:image_env, String.t(), non_neg_integer()}

  @doc "The spec fields an app of this profile has. Admission refuses any other."
  @callback fields() :: [atom()]

  @doc "The keys of `spec.settings` an app of this profile has, each with its default."
  @callback settings() :: %{optional(atom()) => term()}

  @callback backend() :: module()

  @doc "`nil` where the instance is not a container."
  @callback container_name(app :: String.t()) :: String.t() | nil

  @doc "What a stop leaves: nothing, or the stopped container."
  @callback on_stop() :: :remove | :keep | nil

  @doc "Whether an existing container may be started instead of made anew."
  @callback reuse() :: :never | :fingerprint | nil

  @doc "The engine's own restart policy, by its name; `\"\"` is none."
  @callback engine_restart() :: String.t() | nil

  @callback restart_policy(spec()) :: restart_policy()
  @callback readiness(spec()) :: readiness()
  @callback stop_grace(spec()) :: stop_grace()

  @doc "Steps around the instance's own, by name, in no order."
  @callback hooks() :: [atom()]

  @doc "Whether a boot starts the app: as it was, never, or whatever it was."
  @callback boot(spec()) :: :auto | :manual | :always

  @doc "A lower wave starts first."
  @callback wave(spec()) :: pos_integer()

  @doc "How long the app waits for earlier waves before it starts anyway."
  @callback wave_wait_ms(spec()) :: pos_integer()

  @doc "Where the token in the instance's environment comes from."
  @callback token() :: :minted | :supervisor | :none

  @callback backup(spec()) :: :hot | :cold | :excluded | :native

  @profiles %{container: Container, core: Core, native: Native}
  @core_app "homeassistant"

  @spec tags() :: [tag()]
  def tags, do: [:container, :core, :native]

  @spec fetch(term()) :: {:ok, module()} | :error
  def fetch(tag) when is_atom(tag), do: Map.fetch(@profiles, tag)
  def fetch(_other), do: :error

  @doc "The profile of an admitted spec."
  @spec of(spec()) :: module()
  def of(%{lifecycle: tag}), do: Map.fetch!(@profiles, tag)

  @doc "The name of the App resource that is Home Assistant Core."
  @spec core_app() :: String.t()
  def core_app, do: @core_app

  @doc """
  The app a container belongs to, by its name alone, or `nil` for a name
  that is no app's. `addon_<slug>` is what an app's container was called
  before `app_<slug>`, and one may still exist.
  """
  @spec app_of_container(term()) :: String.t() | nil
  def app_of_container("app_" <> slug) when slug != "", do: slug
  def app_of_container("addon_" <> slug) when slug != "", do: slug

  def app_of_container(name) when is_binary(name),
    do: if(name == Core.container_name(@core_app), do: @core_app)

  def app_of_container(_other), do: nil

  @waves %{
    "initialize" => 10,
    "system" => 20,
    "services" => 30,
    "application" => 50,
    "once" => 50
  }
  @default_wave 50

  @doc "The wave of a manifest's `startup`. Core's own is 40, between `services` and the rest."
  @spec wave_of_startup(term()) :: pos_integer()
  def wave_of_startup(startup), do: Map.get(@waves, startup, @default_wave)

  @doc "Upstream's wait for an earlier startup stage."
  @spec default_wave_wait_ms() :: pos_integer()
  def default_wave_wait_ms, do: 120_000

  @doc "The budget of an app whose `watchdog` is on."
  @spec watchdog_budget() :: restart_policy()
  def watchdog_budget do
    {:restart,
     %{
       attempts: 5,
       backoff_ms: 10_000,
       max_sequences: 10,
       sequence_window_ms: :timer.minutes(30),
       reset_after_ms: :timer.minutes(10)
     }}
  end
end
