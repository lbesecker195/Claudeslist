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

      for i <- 1..5, do: Listings.flag_listing(flagged, "203.0.113.#{i}")

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

  describe "flag_listing/2" do
    test "counts one flag per client key and hides after five distinct flaggers" do
      {listing, _} = listing_fixture()

      assert {:ok, :flagged} = Listings.flag_listing(listing, "198.51.100.1")

      for _ <- 1..10,
          do: assert({:ok, :already_flagged} = Listings.flag_listing(listing, "198.51.100.1"))

      assert Listings.get_listing(listing.id).flag_count == 1

      for i <- 2..5, do: Listings.flag_listing(listing, "198.51.100.#{i}")
      assert Listings.get_listing(listing.id) == nil
      assert Listings.get_listing_for_owner(listing.id).flag_count == 5

      assert {:ok, %{flag_count: 0}} = Listings.unhide_listing(listing.id)
      assert Listings.get_listing(listing.id)

      # Unhiding sticks: earlier flaggers can't re-hide it; only new ones count.
      for i <- 1..5, do: Listings.flag_listing(listing, "198.51.100.#{i}")
      assert Listings.get_listing(listing.id).flag_count == 0
      assert {:ok, :flagged} = Listings.flag_listing(listing, "198.51.100.200")
      assert Listings.get_listing(listing.id).flag_count == 1
    end

    test "editing a hidden listing never broadcasts it back onto public pages" do
      {listing, _} = listing_fixture()
      for i <- 1..5, do: Listings.flag_listing(listing, "192.0.2.#{i}")
      hidden = Listings.get_listing_for_owner(listing.id)
      refute Listings.public?(hidden)

      id = listing.id
      Listings.subscribe()
      assert {:ok, _} = Listings.update_listing(hidden, %{"title" => "Sneaky new spam title"})
      refute_receive {:listing_updated, %{id: ^id}}, 100
    end
  end

  test "update_listing/2 with no changes neither writes nor broadcasts" do
    {listing, _} = listing_fixture()
    Listings.subscribe()
    id = listing.id
    assert {:ok, ^listing} = Listings.update_listing(listing, %{"title" => listing.title})
    refute_receive {:listing_updated, %{id: ^id}}, 50
    assert {:ok, _} = Listings.update_listing(listing, %{"title" => "A different title"})
    assert_receive {:listing_updated, %{id: ^id}}
  end

  test "validate_listing/1 and validate_reply/1 never write" do
    assert {:ok, %Ecto.Changeset{}} = Listings.validate_listing(listing_attrs())
    assert {:error, %Ecto.Changeset{action: :insert}} = Listings.validate_listing(%{})
    assert {:error, _} = Listings.validate_reply(%{"from_name" => "x"})
    assert Listings.list_listings() == []
  end
end
