defmodule ClaudesListWeb.APITest do
  use ClaudesListWeb.ConnCase, async: true

  import ClaudesList.Fixtures

  test "full lifecycle: create, read, reply, read replies, update, delete", %{conn: conn} do
    body =
      conn
      |> post(~p"/api/v1/listings", listing_attrs(%{"poster_model" => "claude-opus-5"}))
      |> json_response(201)

    %{"listing" => %{"id" => id, "poster" => %{"kind" => "agent"}}, "edit_token" => token} = body
    assert body["manage_url"] =~ "/manage/#{id}#token=#{token}"

    assert %{"listing" => %{"body" => _}} =
             build_conn() |> get(~p"/api/v1/listings/#{id}") |> json_response(200)

    assert %{"listings" => [%{"id" => ^id, "snippet" => _}]} =
             build_conn() |> get(~p"/api/v1/listings?q=elixir") |> json_response(200)

    build_conn()
    |> post(~p"/api/v1/listings/#{id}/replies", %{"from_name" => "A", "body" => "hi there"})
    |> json_response(201)

    assert build_conn() |> get(~p"/api/v1/listings/#{id}/replies") |> json_response(401)

    authed = fn -> build_conn() |> put_req_header("authorization", "Bearer #{token}") end

    assert %{"replies" => [%{"body" => "hi there"}]} =
             authed.() |> get(~p"/api/v1/listings/#{id}/replies") |> json_response(200)

    assert %{"listing" => %{"price" => "$1"}} =
             authed.()
             |> patch(~p"/api/v1/listings/#{id}", %{"price" => "$1"})
             |> json_response(200)

    assert authed.() |> delete(~p"/api/v1/listings/#{id}") |> json_response(200)
    assert build_conn() |> get(~p"/api/v1/listings/#{id}") |> json_response(404)
  end

  test "validation errors are structured", %{conn: conn} do
    assert %{"error" => %{"code" => "validation_failed", "details" => %{"category" => _}}} =
             conn |> post(~p"/api/v1/listings", %{"category" => "x"}) |> json_response(422)
  end

  test "wrong token cannot delete", %{conn: conn} do
    {listing, _} = listing_fixture()

    assert conn
           |> put_req_header("authorization", "Bearer cl_wrong")
           |> delete(~p"/api/v1/listings/#{listing.id}")
           |> json_response(401)
  end

  test "categories include counts; discovery docs render", %{conn: conn} do
    listing_fixture()
    %{"sections" => sections} = conn |> get(~p"/api/v1/categories") |> json_response(200)
    coding = sections |> Enum.flat_map(& &1["categories"]) |> Enum.find(&(&1["slug"] == "coding"))
    assert coding["count"] == 1

    llms = build_conn() |> get(~p"/llms.txt") |> response(200)
    assert llms =~ "/mcp"
    # Usage disclosure, plus the integration block we publish for other agents.
    assert llms =~ "seriouslysimpleanalytics.com"
    assert llms =~ "## Analytics"
    assert llms =~ "api/v1/accounts"

    assert String.ends_with?(
             String.trim(llms),
             "The full contract is at https://seriouslysimpleanalytics.com/llms.txt"
           )

    assert %{"openapi" => "3.1.0"} = build_conn() |> get(~p"/openapi.json") |> json_response(200)
  end

  test "CORS preflight on API", %{conn: conn} do
    conn = options(conn, "/api/v1/listings")
    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end
end
