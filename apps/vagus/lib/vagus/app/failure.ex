defmodule Vagus.App.Failure do
  @moduledoc """
  What a failed step of an app's lifecycle means: whether trying again can
  help, and what went wrong, by name.

  `classify/2` takes the action that failed and what it returned: a
  `t:Vagus.Runtime.Docker.failure/0`, a backend's own `:already_exists`, or
  the reason of a failed pull (`Vagus.App.Pulls`). The action matters: the
  engine's 404 is a missing image to a pull and a missing container to a
  start, and a stop that timed out has not failed.

    * `:permanent`: the same attempt will fail the same way until the spec
      or the machine changes.
    * `:transient`: worth another attempt.
    * `:pending`: the action is still under way in the engine; look again.

  Anything not listed is `:transient` and `:unknown`: giving up for good on
  a failure nobody has seen before would need a person to undo.

  The engine reports a port conflict in its own words, as a 5xx, and the
  words differ by where the port was taken: `port is already allocated`
  when another container has it, `address already in use` when anything
  else on the host does. Its texts are matched whatever their case.

  A registry that refuses a pull does not say whether the image is private
  or absent, so both are `:pull_denied`; `:image_not_found` is a registry
  that was allowed to look and found no such manifest.
  """

  alias Vagus.App.Pulls

  @type action :: :pull | :create | :start | :stop | :remove | :remove_image | atom()
  @type class :: :permanent | :transient | :pending

  @type cause ::
          :port_conflict
          | :image_not_found
          | :pull_denied
          | :invalid_config
          | :already_exists
          | :name_taken
          | :not_found
          | :still_stopping
          | :engine_unreachable
          | :engine_timeout
          | :engine_transport
          | :engine_error
          | :engine_refused
          | :pull_failed
          | :pull_crashed
          | :unknown

  @typedoc "`detail` is `%{port: port | nil}` for a port conflict and otherwise what failed, as given."
  @type t :: %{class: class(), cause: cause(), detail: term()}

  @port_texts ["address already in use", "port is already allocated"]
  @missing_image_texts ["manifest unknown", "not found"]
  @denied_texts ["unauthorized", "denied", "repository does not exist"]

  @spec classify(action(), term()) :: t()
  def classify(action, reason) do
    {class, cause} = row(action, reason)
    %{class: class, cause: cause, detail: detail(cause, reason)}
  end

  @doc "A pull's state, when it is a failure."
  @spec of_pull(Pulls.state()) :: t() | nil
  def of_pull({:failed, reason, _stamp}), do: classify(:pull, reason)
  def of_pull(_not_failed), do: nil

  defp row(action, {:status, status, message}) when is_integer(status) do
    cond do
      status >= 500 and says?(message, @port_texts) -> {:permanent, :port_conflict}
      action == :pull and says?(message, @denied_texts) -> {:permanent, :pull_denied}
      status == 404 and action == :pull -> {:permanent, :image_not_found}
      status == 404 -> {:transient, :not_found}
      status == 400 -> {:permanent, :invalid_config}
      status >= 500 -> {:transient, :engine_error}
      true -> {:transient, :engine_refused}
    end
  end

  defp row(:pull, {:stream, message}) do
    cond do
      says?(message, @denied_texts) -> {:permanent, :pull_denied}
      says?(message, @missing_image_texts) -> {:permanent, :image_not_found}
      true -> {:transient, :pull_failed}
    end
  end

  defp row(:pull, {:crashed, _reason}), do: {:transient, :pull_crashed}
  # The engine answers a stop when the container has exited. The call gave
  # up; the stop goes on.
  defp row(:stop, {:timeout, _which}), do: {:pending, :still_stopping}
  defp row(_action, {:timeout, _which}), do: {:transient, :engine_timeout}
  defp row(_action, {:unreachable, _reason}), do: {:transient, :engine_unreachable}
  defp row(_action, {:transport, _reason}), do: {:transient, :engine_transport}
  defp row(_action, {:invalid, _term}), do: {:permanent, :invalid_config}
  # What holds the name was made from another config. Removing it is the
  # next pass's to decide, and then this succeeds.
  defp row(_action, :already_exists), do: {:transient, :already_exists}
  defp row(_action, {:other, {:name_taken, _name}}), do: {:transient, :name_taken}
  defp row(_action, _unknown), do: {:transient, :unknown}

  defp says?(message, texts) when is_binary(message),
    do: String.contains?(String.downcase(message), texts)

  defp says?(_no_message, _texts), do: false

  defp detail(:port_conflict, {:status, _status, message}), do: %{port: port(message)}
  defp detail(_cause, reason), do: reason

  # The host side of the binding the engine names, in any of its texts:
  # `Bind for 0.0.0.0:8080 failed`, `Bind for :::8080 failed`, `failed to
  # bind host port for [::]:8080:172.30.33.2:80/tcp`, `listen tcp4
  # 0.0.0.0:8080: bind`, `listen tcp :8080: bind`.
  @host_port ~r/(?:\d{1,3}(?:\.\d{1,3}){3}|\[[0-9a-fA-F:.]*\]|::|tcp[46]? ):(\d{1,5})(?!\d)/

  defp port(message) do
    with [_all, digits] <- Regex.run(@host_port, message),
         port when port in 1..65_535 <- String.to_integer(digits) do
      port
    else
      _none -> nil
    end
  end
end
