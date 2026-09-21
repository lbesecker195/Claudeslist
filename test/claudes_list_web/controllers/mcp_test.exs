defmodule ClaudesListWeb.MCPTest do
  use ClaudesListWeb.ConnCase, async: true

  import ClaudesList.Fixtures

  defp rpc(method, params \\ %{}, id \\ 1) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/mcp", Jason.encode!(%{jsonrpc: "2.0", id: id, method: method, params: params}))
  end

  defp call(name, args),
    do: rpc("tools/call", %{name: name, arguments: args}) |> json_response(200)

  test "initialize negotiates protocol version" do
    assert %{"result" => %{"protocolVersion" => "2025-06-18", "capabilities" => %{"tools" => _}}} =
             rpc("initialize", %{protocolVersion: "2025-06-18"}) |> json_response(200)

    assert %{"result" => %{"protocolVersion" => "2025-11-25"}} =
             rpc("initialize", %{protocolVersion: "1999-01-01"}) |> json_response(200)
  end

  test "notifications get 202" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/mcp", Jason.encode!(%{jsonrpc: "2.0", method: "notifications/initialized"}))

    assert conn.status == 202
  end

  test "tools/list exposes the catalogue" do
    %{"result" => %{"tools" => tools}} = rpc("tools/list") |> json_response(200)
    names = Enum.map(tools, & &1["name"])
    assert "create_listing" in names and "reply_to_listing" in names
  end

  test "create, search, reply and read replies via tools" do
    %{"result" => %{"structuredContent" => created}} =
      call("create_listing", Map.delete(listing_attrs(), "poster_kind"))

    id = created["listing"]["id"]
    token = created["edit_token"]

    %{"result" => %{"structuredContent" => %{"listings" => [%{"id" => ^id}]}}} =
      call("search_listings", %{"q" => "elixir"})

    %{"result" => %{"isError" => true}} =
      call("read_replies", %{"id" => id, "edit_token" => "no"})

    call("reply_to_listing", %{"id" => id, "from_name" => "Bot", "body" => "hello"})

    %{"result" => %{"structuredContent" => %{"count" => 1}}} =
      call("read_replies", %{"id" => id, "edit_token" => token})
  end

  test "validation failures are tool errors, not protocol errors" do
    %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
      call("create_listing", %{
        "category" => "zzz",
        "title" => "hi",
        "body" => "b",
        "poster_name" => "x"
      })

    assert text =~ "Validation failed"
  end

  test "unknown tool and method are JSON-RPC errors" do
    assert %{"error" => %{"code" => -32602}} = call("nope", %{})
    assert %{"error" => %{"code" => -32601}} = rpc("resources/list") |> json_response(200)
  end

  test "batches return one reply per request" do
    {listing, _} = listing_fixture()

    batch = [
      %{jsonrpc: "2.0", id: 1, method: "ping"},
      %{jsonrpc: "2.0", method: "notifications/initialized"},
      %{
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: %{name: "get_listing", arguments: %{id: listing.id}}
      }
    ]

    replies =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/mcp", Jason.encode!(batch))
      |> json_response(200)

    assert Enum.map(replies, & &1["id"]) == [1, 2]
  end

  test "GET is not allowed" do
    assert build_conn() |> get(~p"/mcp") |> json_response(405)
  end
end
