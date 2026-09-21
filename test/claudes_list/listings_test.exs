defmodule ClaudesList.ListingsTest do
  use ClaudesList.DataCase, async: true

  import ClaudesList.Fixtures
  alias ClaudesList.{Listings, Repo}
  alias ClaudesList.Listings.Listing

  describe "create_listing/1" do
    test "returns a token that verifies, and stores only its hash" do
      {listing, token} = listing_fixture()
      assert "cl_" <> _ = token
      assert Listings.verify_token(listing, token)
      refute Listings.verify_token(listing, token <> "x")
      refute Listings.verify_token(listing, nil)
      refute listing.edit_token_hash == token
    end

    test "normalizes tags and sets a 30 day expiry" do
      {listing, _} = listing_fixture(%{"tags" => ["Rust", " rust ", "", "AI"]})
      assert listing.tags == ["rust", "ai"]
      assert DateTime.diff(listing.expires_at, DateTime.utc_now(), :day) in 29..30
    end

    test "rejects unknown categories and short fields" do
      assert {:error, cs} =
               Listings.create_listing(listing_attrs(%{"category" => "nope", "title" => "x"}))

      assert %{category: [_], title: [_]} = errors_on(cs)
    end
  end

  describe "list_listings/1" do
    test "filters by category, section, tag, kind and full-text search" do
      {a, _} = listing_fixture(%{"title" => "Postgres migration reviewer"})

      {b, _} =
        listing_fixture(%{
          "category" => "datasets",
          "title" => "Pricing dataset",
          "tags" => ["saas"],
          "poster_kind" => "human"
        })

      ids = fn opts -> opts |> Listings.list_listings() |> Enum.map(& &1.id) end

      assert ids.(category: "coding") == [a.id]
      assert ids.(section: "for-sale") == [b.id]
      assert ids.(tag: "SAAS") == [b.id]
      assert ids.(poster_kind: "human") == [b.id]
      assert ids.(q: "postgres migration") == [a.id]
      assert ids.([]) == [b.id, a.id]
      assert ids.(before_id: b.id) == [a.id]
    end

    test "hides expired and heavily flagged listings" do
      {expired, _} = listing_fixture()
      {flagged, _} = listing_fixture()
      {ok, _} = listing_fixture()

      Repo.update_all(from(l in Listing, where: l.id == ^expired.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :day)]
      )

      for _ <- 1..5, do: Listings.flag_listing(flagged)

      assert Listings.list_listings() |> Enum.map(& &1.id) == [ok.id]
      assert Listings.get_listing(expired.id) == nil
      assert Listings.get_listing("not-an-id") == nil
    end
  end

  test "create_reply/2 increments reply_count and broadcasts to the listing topic" do
    {listing, _} = listing_fixture()
    Phoenix.PubSub.subscribe(ClaudesList.PubSub, "listing:#{listing.id}")

    assert {:ok, reply} =
             Listings.create_reply(listing, %{"from_name" => "Asker", "body" => "Interested"})

    assert_receive {:reply_created, _, ^reply}
    assert Listings.get_listing(listing.id).reply_count == 1
    assert [^reply] = Listings.list_replies(listing)
  end

  test "janitor purges listings expired more than a week ago" do
    {old, _} = listing_fixture()
    {recent, _} = listing_fixture()

    Repo.update_all(from(l in Listing, where: l.id == ^old.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -8, :day)]
    )

    Repo.update_all(from(l in Listing, where: l.id == ^recent.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :day)]
    )

    assert ClaudesList.Listings.Janitor.purge() == 1
    assert Repo.get(Listing, recent.id)
  end
end
