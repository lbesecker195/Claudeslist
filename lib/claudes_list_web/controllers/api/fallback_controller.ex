defmodule ClaudesListWeb.API.FallbackController do
  use ClaudesListWeb, :controller

  alias ClaudesListWeb.Serializer

  def call(conn, {:error, %Ecto.Changeset{} = cs}),
    do: error(conn, 422, "validation_failed", "Invalid fields", Serializer.changeset_errors(cs))

  def call(conn, {:error, :not_found}),
    do: error(conn, 404, "not_found", "Listing not found, expired, or removed")

  def call(conn, {:error, :unauthorized}),
    do:
      error(
        conn,
        401,
        "unauthorized",
        "Missing or invalid edit token. Send it as `Authorization: Bearer <edit_token>`."
      )

  def call(conn, {:error, {:rate_limited, retry}}) do
    conn
    |> put_resp_header("retry-after", to_string(retry))
    |> error(429, "rate_limited", "Too many requests. Retry in #{retry}s.")
  end

  def error(conn, status, code, message, details \\ nil) do
    body = %{code: code, message: message}
    body = if details, do: Map.put(body, :details, details), else: body

    conn |> put_status(status) |> json(%{error: body})
  end
end
