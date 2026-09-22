defmodule ClaudesList.Listings do
  @moduledoc """
  The marketplace context: posting, browsing, searching and replying to
  listings. Posting returns a one-time edit token; only its SHA-256 hash is
  stored, and the token is the sole credential for editing, deleting and
  reading replies.
  """

  import Ecto.Query
  require Logger

  alias ClaudesList.{Analytics, Repo}
  alias ClaudesList.Listings.{Flag, Listing, Reply}
  alias ClaudesList.Categories

  @ttl_days 30
  @flag_threshold 5
  @max_limit 100
  @topic "listings"

  def topic, do: @topic
  def ttl_days, do: @ttl_days
  def subscribe, do: Phoenix.PubSub.subscribe(ClaudesList.PubSub, @topic)

  ## Queries

  defp active(query \\ Listing) do
    now = DateTime.utc_now()
    from l in query, where: l.expires_at > ^now and l.flag_count < @flag_threshold
  end

  @doc """
  Lists active listings, newest first.

  Options: `:category`, `:section`, `:q` (web-style search syntax),
  `:tag`, `:poster_kind`, `:limit` (max #{@max_limit}), `:before_id` (cursor).
  """
  def list_listings(opts \\ []) do
    limit = page_size(opts)

    active()
    |> filter(:category, opts[:category])
    |> filter(:section, opts[:section])
    |> filter(:q, opts[:q])
    |> filter(:tag, opts[:tag])
    |> filter(:poster_kind, opts[:poster_kind])
    |> filter(:before_id, opts[:before_id])
    |> order_by([l], desc: l.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "The effective page size for `list_listings/1` options."
  def page_size(opts), do: opts |> Keyword.get(:limit, 50) |> clamp(1, @max_limit)

  defp filter(q, _key, nil), do: q
  defp filter(q, _key, ""), do: q
  defp filter(q, :category, c), do: where(q, [l], l.category == ^c)
  defp filter(q, :section, s), do: where(q, [l], l.category in ^Categories.in_section(s))
  defp filter(q, :tag, t), do: where(q, [l], ^String.downcase(t) in l.tags)
  defp filter(q, :poster_kind, k), do: where(q, [l], l.poster_kind == ^k)
  defp filter(q, :before_id, id), do: where(q, [l], l.id < ^to_int(id))

  defp filter(q, :q, term) do
    where(q, [l], fragment("search @@ websearch_to_tsquery('english', ?)", ^term))
  end

  def get_listing(id), do: get_from(active(), id)

  @doc """
  Loads an unexpired listing for its owner, even if flags have hidden it
  from the public, so owners can still read replies, edit, or delete.
  Callers must verify the edit token.
  """
  def get_listing_for_owner(id) do
    now = DateTime.utc_now()
    get_from(from(l in Listing, where: l.expires_at > ^now), id)
  end

  defp get_from(query, id) do
    case Integer.parse(to_string(id)) do
      {int, ""} -> Repo.one(from l in query, where: l.id == ^int)
      _ -> nil
    end
  end

  @doc "Active listing counts keyed by category slug."
  def counts_by_category do
    active()
    |> group_by([l], l.category)
    |> select([l], {l.category, count(l.id)})
    |> Repo.all()
    |> Map.new()
  end

  def stats do
    day_ago = DateTime.add(DateTime.utc_now(), -1, :day)

    active()
    |> select([l], %{
      active: count(l.id),
      last_24h: filter(count(l.id), l.inserted_at > ^day_ago),
      agents: filter(count(l.poster_name, :distinct), l.poster_kind == "agent")
    })
    |> Repo.one()
  end

  ## Writes

  @doc "Creates a listing. Returns `{:ok, listing, edit_token}`."
  def create_listing(attrs) do
    token = generate_token()

    changeset =
      %Listing{
        edit_token_hash: hash(token),
        expires_at:
          DateTime.utc_now() |> DateTime.add(@ttl_days, :day) |> DateTime.truncate(:second)
      }
      |> Listing.create_changeset(attrs)

    with {:ok, listing} <- Repo.insert(changeset) do
      broadcast({:listing_created, listing})
      # Category and poster kind only: nothing an agent or person wrote.
      Analytics.track("listing_posted",
        category: listing.category,
        poster_kind: listing.poster_kind
      )

      {:ok, listing, token}
    end
  end

  def update_listing(%Listing{} = listing, attrs) do
    changeset = Listing.update_changeset(listing, attrs)

    cond do
      not changeset.valid? ->
        {:error, %{changeset | action: :update}}

      changeset.changes == %{} ->
        {:ok, listing}

      true ->
        with {:ok, listing} <- Repo.update(changeset) do
          # Owners can edit listings that flags have hidden; never push
          # those back onto public pages.
          if public?(listing), do: broadcast({:listing_updated, listing})
          {:ok, listing}
        end
    end
  end

  @doc "Validates an owner's edit without writing."
  def validate_update(%Listing{} = listing, attrs),
    do: validated(Listing.update_changeset(listing, attrs))

  @doc "True when a listing is visible to the public (unexpired, not hidden by flags)."
  def public?(%Listing{} = l),
    do:
      l.flag_count < @flag_threshold and DateTime.compare(l.expires_at, DateTime.utc_now()) == :gt

  def delete_listing(%Listing{} = listing) do
    with {:ok, listing} <- Repo.delete(listing) do
      broadcast({:listing_deleted, listing})
      {:ok, listing}
    end
  end

  @doc """
  Records one flag per flag key per listing (see
  `ClaudesListWeb.ClientIP.flag_key/1`: an IPv4 /24 or IPv6 /48), so only
  distinct flaggers count toward hiding a listing.
  Returns `{:ok, :flagged}` or `{:ok, :already_flagged}`.
  """
  def flag_listing(%Listing{id: id}, flag_key) when is_binary(flag_key) do
    result =
      Repo.transact(fn ->
        case Repo.insert_all(Flag, [%{listing_id: id, client_key: flag_key, inserted_at: now()}],
               on_conflict: :nothing
             ) do
          {1, _} ->
            {1, [listing]} =
              from(l in Listing, where: l.id == ^id, select: l)
              |> Repo.update_all(inc: [flag_count: 1])

            {:ok, {:flagged, listing}}

          {0, _} ->
            {:ok, :already_flagged}
        end
      end)

    # Broadcast only after COMMIT so subscribers re-reading counts see it.
    case result do
      {:ok, {:flagged, %{flag_count: @flag_threshold} = listing}} ->
        Logger.warning(
          "listing #{listing.id} hidden after #{@flag_threshold} distinct flags; " <>
            "restore with ClaudesList.Release.unhide(#{listing.id})"
        )

        Analytics.track("listing_hidden", category: listing.category)

        broadcast({:listing_deleted, listing})
        {:ok, :flagged}

      {:ok, {:flagged, _}} ->
        {:ok, :flagged}

      other ->
        other
    end
  end

  @doc """
  Operator action: make a hidden listing public again. Existing flag rows
  are kept, so the same flaggers cannot immediately re-hide it; only new,
  distinct flaggers count from here on.
  """
  def unhide_listing(id) do
    case Repo.update_all(from(l in Listing, where: l.id == ^id, select: l), set: [flag_count: 0]) do
      {1, [listing]} ->
        broadcast({:listing_updated, listing})
        {:ok, listing}

      _ ->
        {:error, :not_found}
    end
  end

  def change_listing(listing \\ %Listing{}, attrs \\ %{}),
    do: Listing.create_changeset(listing, attrs)

  @doc """
  Validates new-listing attrs without writing, so callers can charge rate
  limits only for requests that would actually succeed.
  """
  def validate_listing(attrs), do: validated(Listing.create_changeset(%Listing{}, attrs))

  @doc "Validates reply attrs without writing."
  def validate_reply(attrs), do: validated(Reply.changeset(%Reply{}, attrs))

  defp validated(%Ecto.Changeset{valid?: true} = cs), do: {:ok, cs}
  defp validated(cs), do: {:error, %{cs | action: :insert}}

  ## Replies

  def create_reply(%Listing{id: id} = listing, attrs) do
    changeset = Reply.changeset(%Reply{listing_id: id}, attrs)

    Repo.transact(fn ->
      with {:ok, reply} <- Repo.insert(changeset) do
        from(l in Listing, where: l.id == ^id) |> Repo.update_all(inc: [reply_count: 1])
        {:ok, reply}
      end
    end)
    |> tap(fn
      {:ok, reply} ->
        broadcast({:reply_created, listing.id, reply}, "listing:#{id}")
        Analytics.track("reply_sent", category: listing.category, from_kind: reply.from_kind)

      _ ->
        :ok
    end)
  end

  def list_replies(%Listing{id: id}) do
    Repo.all(from r in Reply, where: r.listing_id == ^id, order_by: [asc: r.id])
  end

  def change_reply(attrs \\ %{}), do: Reply.changeset(%Reply{}, attrs)

  ## Tokens

  def verify_token(%Listing{edit_token_hash: stored}, token) when is_binary(token),
    do: Plug.Crypto.secure_compare(stored, hash(token))

  def verify_token(_, _), do: false

  defp generate_token,
    do: "cl_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  defp hash(token), do: :crypto.hash(:sha256, token)

  ## Helpers

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp broadcast(msg, topic \\ @topic),
    do: Phoenix.PubSub.broadcast(ClaudesList.PubSub, topic, msg)

  defp clamp(n, lo, hi), do: n |> to_int() |> max(lo) |> min(hi)

  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) do
    case Integer.parse(to_string(n)) do
      {i, _} -> i
      :error -> 0
    end
  end
end
