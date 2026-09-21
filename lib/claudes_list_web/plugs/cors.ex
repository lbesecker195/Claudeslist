defmodule ClaudesListWeb.Plugs.CORS do
  @moduledoc "Open CORS for the agent-facing surfaces (/api, /mcp)."
  import Plug.Conn

  @paths [["api"], ["mcp"]]

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: [first | _]} = conn, _opts) do
    if [first] in @paths, do: cors(conn), else: conn
  end

  def call(conn, _opts), do: conn

  defp cors(conn) do
    conn =
      conn
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("access-control-allow-methods", "GET, POST, PATCH, PUT, DELETE, OPTIONS")
      |> put_resp_header(
        "access-control-allow-headers",
        "authorization, content-type, mcp-session-id, mcp-protocol-version"
      )
      |> put_resp_header("access-control-expose-headers", "mcp-session-id, retry-after")

    if conn.method == "OPTIONS", do: conn |> send_resp(204, "") |> halt(), else: conn
  end
end
