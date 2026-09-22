defmodule ClaudesListWeb.PagesTest do
  use ClaudesListWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ClaudesList.Fixtures

  test "home shows categories and pushes new listings to the live feed", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "humans wanted"
    assert html =~ "/mcp"

    {listing, _} = listing_fixture(%{"title" => "Brand new live listing"})
    assert render(view) =~ "Brand new live listing"
    assert has_element?(view, "#feed-#{listing.id}.cl-fresh")
  end

  test "category page lists and filters listings", %{conn: conn} do
    listing_fixture(%{"title" => "Agent-posted coding gig"})
    listing_fixture(%{"title" => "Human-posted coding gig", "poster_kind" => "human"})

    {:ok, view, html} = live(conn, ~p"/c/coding")
    assert html =~ "Agent-posted coding gig"

    view |> form("#filters", f: %{kind: "human"}) |> render_change()
    assert_patch(view, ~p"/c/coding?kind=human")
    refute render(view) =~ "Agent-posted coding gig"
    assert render(view) =~ "Human-posted coding gig"
  end

  test "unknown category is a 404", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, ~p"/c/not-a-thing") end
  end

  test "listing page accepts replies", %{conn: conn} do
    {listing, _} = listing_fixture()
    {:ok, view, _} = live(conn, ~p"/l/#{listing.id}")

    view
    |> form("#reply-form", reply: %{from_name: "Human Hank", body: "When can you start?"})
    |> render_submit()

    assert render(view) =~ "Reply sent"
    assert [%{from_name: "Human Hank"}] = ClaudesList.Listings.list_replies(listing)
  end

  test "posting from the web returns a manage link", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/post")

    html =
      view
      |> form("#post-form",
        listing: %{
          category: "datasets",
          title: "Web posted dataset",
          body: "A dataset posted from the web form.",
          tags: "csv, open",
          poster_name: "Web Wendy"
        }
      )
      |> render_submit()

    assert html =~ "Your posting is live"
    assert html =~ "/manage/"
    assert [%{tags: ["csv", "open"], poster_kind: "human"}] = ClaudesList.Listings.list_listings()
  end

  test "manage page unlocks with the token and receives replies live", %{conn: conn} do
    {listing, token} = listing_fixture(%{"title" => "Secret-ish title here"})
    {:ok, view, html} = live(conn, ~p"/manage/#{listing.id}")
    assert html =~ "edit token"
    refute html =~ "Secret-ish title here"

    render_submit(view, "auth", %{"token" => "cl_wrong"})
    assert render(view) =~ "doesn&#39;t match"

    render_submit(view, "auth", %{"token" => token})
    assert render(view) =~ "edit posting"

    ClaudesList.Listings.create_reply(listing, %{"from_name" => "Live Larry", "body" => "ping"})
    assert render(view) =~ "Live Larry"
  end

  test "agents docs render", %{conn: conn} do
    assert conn |> get(~p"/agents") |> html_response(200) =~ "claude mcp add"
  end

  test "manage page still works for a listing hidden by flags", %{conn: conn} do
    {listing, token} = listing_fixture()
    for i <- 1..5, do: ClaudesList.Listings.flag_listing(listing, "198.18.1.#{i}")

    assert_error_sent 404, fn -> get(conn, ~p"/l/#{listing.id}") end

    {:ok, view, _} = live(build_conn(), ~p"/manage/#{listing.id}")
    render_submit(view, "auth", %{"token" => token})
    assert render(view) =~ "hidden from the public"
  end
end
