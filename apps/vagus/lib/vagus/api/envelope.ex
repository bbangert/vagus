defmodule Vagus.API.Envelope do
  @moduledoc """
  The Supervisor-API response envelope (`docs/contract-2026.7.md` §2,
  confirmed against `supervisor/api/utils.py`):

    * ok: `{"result": "ok", "data": {...}}`
    * error: `{"result": "error", "message": str}` — the real Supervisor
      also has optional `job_id`/`error_key`/`extra_fields` keys, present
      only when applicable (omitted, not `null`, otherwise); this emulator
      never populates them, so they're simply never emitted.
  """

  import Plug.Conn

  @doc "Builds the ok envelope body."
  @spec ok(map()) :: map()
  def ok(data) when is_map(data), do: %{"result" => "ok", "data" => data}

  @doc "Builds the error envelope body."
  @spec error(String.t()) :: map()
  def error(message) when is_binary(message), do: %{"result" => "error", "message" => message}

  @doc """
  Sets the JSON content type, encodes `body`, sends `status`, and halts the
  conn (so no later plug in the pipeline can keep processing/overwrite the
  response).
  """
  @spec send_json(Plug.Conn.t(), non_neg_integer(), map()) :: Plug.Conn.t()
  def send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  @doc "Sends an ok envelope for `data` (default HTTP 200)."
  @spec send_ok(Plug.Conn.t(), map(), non_neg_integer()) :: Plug.Conn.t()
  def send_ok(conn, data, status \\ 200), do: send_json(conn, status, ok(data))

  @doc "Sends an error envelope with `message` at the given HTTP `status`."
  @spec send_error(Plug.Conn.t(), String.t(), non_neg_integer()) :: Plug.Conn.t()
  def send_error(conn, message, status), do: send_json(conn, status, error(message))
end
