defmodule Vagus.Core.Notification do
  @moduledoc """
  Home Assistant persistent notifications, raised and dismissed through
  Core's own service API. Under a fixed `notification_id` a second `create/1`
  replaces what Home Assistant shows rather than adding another, and a
  `dismiss/1` of one that is not shown succeeds.
  """

  @spec create(map()) :: :ok | {:error, term()}
  def create(%{"notification_id" => _} = notification),
    do: post("/api/services/persistent_notification/create", notification)

  @spec dismiss(String.t()) :: :ok | {:error, term()}
  def dismiss(id) when is_binary(id),
    do: post("/api/services/persistent_notification/dismiss", %{"notification_id" => id})

  defp post(path, body) do
    case Vagus.Core.Client.request(:post, path,
           headers: [{"content-type", "application/json"}],
           body: Jason.encode!(body)
         ) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 -> :ok
      other -> {:error, other}
    end
  catch
    # An unstarted Core.Client exits :noproc.
    :exit, reason -> {:error, {:exit, reason}}
  end
end
