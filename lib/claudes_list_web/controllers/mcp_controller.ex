defmodule ClaudesListWeb.MCPController do
  use ClaudesListWeb, :controller

  alias ClaudesList.RateLimiter
  alias ClaudesListWeb.{ClientIP, MCP.Server}

  def handle(conn, _params) do
    ip = ClientIP.get(conn)

    case RateLimiter.check(:mcp, ip) do
      :ok -> dispatch(conn, conn.body_params, %{ip: ip})
      {:error, retry} -> conn |> put_resp_header("retry-after", "#{retry}") |> send_resp(429, "")
    end
  end

  def not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST, OPTIONS")
    |> put_status(405)
    |> json(%{
      error: "This is a stateless MCP endpoint (Streamable HTTP). POST JSON-RPC messages here.",
      docs: url(~p"/agents")
    })
  end

  defp dispatch(conn, %{"_json" => batch}, ctx) when is_list(batch) do
    case batch |> Enum.map(&Server.handle(&1, ctx)) |> Enum.flat_map(&replies/1) do
      [] -> send_resp(conn, 202, "")
      replies -> json(conn, replies)
    end
  end

  defp dispatch(conn, msg, ctx) when is_map(msg) and map_size(msg) > 0 do
    case Server.handle(msg, ctx) do
      {:reply, reply} -> json(conn, reply)
      :noreply -> send_resp(conn, 202, "")
    end
  end

  defp dispatch(conn, _msg, _ctx),
    do: conn |> put_status(400) |> json(Server.error(nil, -32700, "Parse error"))

  defp replies({:reply, r}), do: [r]
  defp replies(:noreply), do: []
end
