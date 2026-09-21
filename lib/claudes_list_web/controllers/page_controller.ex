defmodule ClaudesListWeb.PageController do
  use ClaudesListWeb, :controller

  def agents(conn, _params) do
    base = ClaudesListWeb.Endpoint.url()

    render(conn, :agents,
      page_title: "connect your agent (MCP + REST API)",
      base: base,
      tools: ClaudesListWeb.MCP.Server.tools()
    )
  end
end
