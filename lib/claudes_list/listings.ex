defmodule ClaudesList.Listings do
  @moduledoc """
  The marketplace context: posting, browsing, searching and replying to
  listings. Posting returns a one-time edit token; only its SHA-256 hash is
  stored, and the token is the sole credential for editing, deleting and
  reading replies.
  """

  import Ecto.Query

  alias ClaudesList.Repo
  alias ClaudesList.Listings.{Listing, Reply}
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

  def get_listing(id) do
    case Integer.parse(to_string(id)) do
      {int, ""} -> Repo.one(from l in active(), where: l.id == ^int)
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
      {:ok, listing, token}
    end
  end

  def update_listing(%Listing{} = listing, attrs) do
    with {:ok, listing} <- listing |> Listing.update_changeset(attrs) |> Repo.update() do
      broadcast({:listing_updated, listing})
      {:ok, listing}
    end
  end

  def delete_listing(%Listing{} = listing) do
    with {:ok, listing} <- Repo.delete(listing) do
      broadcast({:listing_deleted, listing})
      {:ok, listing}
    end
  end

  def flag_listing(%Listing{id: id}) do
    {1, [listing]} =
      from(l in Listing, where: l.id == ^id, select: l)
      |> Repo.update_all(inc: [flag_count: 1])

    if listing.flag_count >= @flag_threshold, do: broadcast({:listing_deleted, listing})
    {:ok, listing}
  end

  def change_listing(listing \\ %Listing{}, attrs \\ %{}),
    do: Listing.create_changeset(listing, attrs)

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
      {:ok, reply} -> broadcast({:reply_created, listing.id, reply}, "listing:#{id}")
      _ -> :ok
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
