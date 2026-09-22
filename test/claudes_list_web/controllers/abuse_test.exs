defmodule ClaudesListWeb.AbuseTest do
  @moduledoc "Rate limiting, batching, and flagging defenses. Synchronous: mutates app env."
  use ClaudesListWeb.ConnCase, async: false

  import ClaudesList.Fixtures

  setup do
    limits = Application.get_env(:claudes_list, :rate_limits)
    Application.put_env(:claudes_list, :client_ip_header, "x-real-ip")

    on_exit(fn ->
      Application.put_env(:claudes_list, :rate_limits, limits)
      Application.delete_env(:claudes_list, :client_ip_header)
    end)

    %{ip: ClaudesList.TestIP.unique()}
  end

  defp as(ip), do: build_conn() |> put_req_header("x-real-ip", ip)

  defp mcp(ip, body) do
    as(ip)
    |> put_req_header("content-type", "application/json")
    |> post(~p"/mcp", Jason.encode!(body))
  end

  defp ping(i), do: %{jsonrpc: "2.0", id: i, method: "ping"}

  test "MCP batches over 20 messages are rejected outright", %{ip: ip} do
    assert %{"error" => %{"code" => -32600}} =
             mcp(ip, Enum.map(1..21, &ping/1)) |> json_response(400)

    assert length(mcp(ip, Enum.map(1..20, &ping/1)) |> json_response(200)) == 20
  end

  test "each batch element costs one unit of MCP quota", %{ip: ip} do
    Application.put_env(:claudes_list, :rate_limits, %{mcp: 25})
    assert mcp(ip, Enum.map(1..20, &ping/1)).status == 200
    assert mcp(ip, Enum.map(1..5, &ping/1)).status == 200
    # 25 units spent: even a single message is now over quota.
    assert mcp(ip, ping(1)).status == 429
  end

  test "invalid posts do not consume the post quota", %{ip: ip} do
    Application.put_env(:claudes_list, :rate_limits, %{post: 1})

    for _ <- 1..5,
        do: assert(as(ip) |> post(~p"/api/v1/listings", %{"title" => "x"}) |> json_response(422))

    assert as(ip) |> post(~p"/api/v1/listings", listing_attrs()) |> json_response(201)
    assert as(ip) |> post(~p"/api/v1/listings", listing_attrs()) |> json_response(429)
  end

  test "edits are rate limited", %{ip: ip} do
    Application.put_env(:claudes_list, :rate_limits, %{edit: 2})
    {listing, token} = listing_fixture()

    patch_price = fn p ->
      as(ip)
      |> put_req_header("authorization", "Bearer #{token}")
      |> patch(~p"/api/v1/listings/#{listing.id}", %{"price" => p})
    end

    assert patch_price.("$1").status == 200
    assert patch_price.("$2").status == 200
    assert patch_price.("$3").status == 429
  end

  test "edit tokens are only accepted from the Authorization header", %{ip: ip} do
    {listing, token} = listing_fixture()

    assert as(ip)
           |> get(~p"/api/v1/listings/#{listing.id}/replies?edit_token=#{token}")
           |> json_response(401)

    assert as(ip)
           |> put_req_header("authorization", "bearer #{token}")
           |> get(~p"/api/v1/listings/#{listing.id}/replies")
           |> json_response(200)
  end

  test "one client flagging repeatedly cannot hide a listing", %{ip: ip} do
    {listing, _} = listing_fixture()
    for _ <- 1..10, do: as(ip) |> post(~p"/api/v1/listings/#{listing.id}/flag")
    assert build_conn() |> get(~p"/api/v1/listings/#{listing.id}") |> json_response(200)
  end

  test "IPv6 clients in one /64 share a flag", %{ip: _ip} do
    {listing, _} = listing_fixture()
    for i <- 1..10, do: as("2001:db8:5:6::#{i}") |> post(~p"/api/v1/listings/#{listing.id}/flag")
    assert ClaudesList.Listings.get_listing(listing.id).flag_count == 1
  end

  test "owners keep access to a listing hidden by flags", %{ip: ip} do
    {listing, token} = listing_fixture()
    ClaudesList.Listings.create_reply(listing, %{"from_name" => "Buyer", "body" => "still here?"})
    # Five distinct networks (flags count once per IPv4 /24).
    for _ <- 1..5,
        do: as(ClaudesList.TestIP.unique_v4()) |> post(~p"/api/v1/listings/#{listing.id}/flag")

    assert build_conn() |> get(~p"/api/v1/listings/#{listing.id}") |> json_response(404)

    owner = fn -> as(ip) |> put_req_header("authorization", "Bearer #{token}") end

    assert %{"replies" => [_]} =
             owner.() |> get(~p"/api/v1/listings/#{listing.id}/replies") |> json_response(200)

    %{"result" => %{"structuredContent" => %{"count" => 1}}} =
      mcp(ip, %{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "read_replies", arguments: %{id: listing.id, edit_token: token}}
      })
      |> json_response(200)

    assert owner.() |> delete(~p"/api/v1/listings/#{listing.id}") |> json_response(200)
  end

  test "addresses in one IPv4 /24 count as a single flagger", %{ip: _} do
    {listing, _} = listing_fixture()
    for i <- 1..10, do: as("198.18.77.#{i}") |> post(~p"/api/v1/listings/#{listing.id}/flag")
    assert ClaudesList.Listings.get_listing(listing.id).flag_count == 1
  end

  test "invalid MCP posts do not consume the post quota", %{ip: ip} do
    Application.put_env(:claudes_list, :rate_limits, %{post: 1})

    call = fn args ->
      mcp(ip, %{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "create_listing", arguments: args}
      })
      |> json_response(200)
    end

    for _ <- 1..3, do: assert(%{"result" => %{"isError" => true}} = call.(%{"title" => "x"}))

    assert %{"result" => %{"structuredContent" => %{"edit_token" => _}}} =
             call.(Map.delete(listing_attrs(), "poster_kind"))

    assert %{"result" => %{"isError" => true, "content" => [%{"text" => "Rate limited" <> _}]}} =
             call.(Map.delete(listing_attrs(), "poster_kind"))
  end

  test "bad tokens and invalid edits do not consume the edit quota", %{ip: ip} do
    Application.put_env(:claudes_list, :rate_limits, %{edit: 1})
    {listing, token} = listing_fixture()
    with_token = fn t -> as(ip) |> put_req_header("authorization", "Bearer #{t}") end

    for _ <- 1..3,
        do:
          assert(
            with_token.("cl_wrong")
            |> patch(~p"/api/v1/listings/#{listing.id}", %{"price" => "$9"})
            |> json_response(401)
          )

    assert with_token.(token)
           |> patch(~p"/api/v1/listings/#{listing.id}", %{"title" => "x"})
           |> json_response(422)

    assert with_token.(token)
           |> patch(~p"/api/v1/listings/#{listing.id}", %{"price" => "$9"})
           |> json_response(200)

    assert with_token.(token)
           |> patch(~p"/api/v1/listings/#{listing.id}", %{"price" => "$8"})
           |> json_response(429)
  end
end
