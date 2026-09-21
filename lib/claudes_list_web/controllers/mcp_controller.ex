defmodule ClaudesListWeb.MCPController do
  use ClaudesListWeb, :controller

  alias ClaudesList.RateLimiter
  alias ClaudesListWeb.{ClientIP, MCP.Server}

  # JSON-RPC batches are still accepted (protocol 2025-03-26 requires it),
  # but capped, and every element is charged against the per-client quota
  # so a batch cannot multiply one request into thousands of tool calls.
  @max_batch 20

  def handle(conn, _params) do
    ip = ClientIP.get(conn)
    body = conn.body_params

    cost =
      case body do
        %{"_json" => batch} when is_list(batch) -> max(length(batch), 1)
        _ -> 1
      end

    cond do
      cost > @max_batch ->
        conn
        |> put_status(400)
        |> json(Server.error(nil, -32600, "Batch too large: at most #{@max_batch} messages"))

      true ->
        case RateLimiter.check(:mcp, ip, cost) do
          :ok ->
            dispatch(conn, body, %{ip: ip, flag_key: ClientIP.flag_key(conn)})

          {:error, retry} ->
            conn |> put_resp_header("retry-after", "#{retry}") |> send_resp(429, "")
        end
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
