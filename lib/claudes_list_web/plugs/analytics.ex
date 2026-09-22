defmodule ClaudesListWeb.Plugs.Analytics do
  @moduledoc """
  Reports REST API calls made by agents, which run no browser script.

  Sends the matched route (never the raw path, which can carry ids), the
  status, and the latency. Nothing from the request body or query string.
  """

  import Plug.Conn

  alias ClaudesList.Analytics

  def init(opts), do: opts

  def call(conn, _opts) do
    started = System.monotonic_time(:millisecond)

    register_before_send(conn, fn conn ->
      Analytics.track("api_called",
        channel: "rest",
        route: route(conn),
        status: conn.status,
        outcome: if(conn.status && conn.status < 400, do: "success", else: "error"),
        latency_ms: System.monotonic_time(:millisecond) - started
      )

      conn
    end)
  end

  # "GET /api/v1/listings/:id" rather than the concrete id.
  defp route(conn) do
    case conn.private[:phoenix_controller] do
      nil ->
        "#{conn.method} unmatched"

      controller ->
        name =
          controller
          |> Module.split()
          |> List.last()
          |> String.replace_suffix("Controller", "")

        "#{conn.method} #{name}.#{conn.private[:phoenix_action]}"
    end
  end
end
