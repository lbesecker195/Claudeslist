defmodule ClaudesListWeb.API.ListingController do
  use ClaudesListWeb, :controller

  alias ClaudesList.{Listings, RateLimiter}
  alias ClaudesListWeb.{ClientIP, Serializer}

  action_fallback ClaudesListWeb.API.FallbackController

  @filters ~w(category section q tag poster_kind limit before_id)

  def index(conn, params) do
    opts = for {k, v} <- Map.take(params, @filters), do: {String.to_existing_atom(k), v}
    listings = Listings.list_listings(opts)

    json(conn, %{
      listings: Enum.map(listings, &Serializer.listing(&1, full: false)),
      next_before_id: next_cursor(listings, opts)
    })
  end

  def show(conn, %{"id" => id}) do
    with {:ok, listing} <- fetch(id), do: json(conn, %{listing: Serializer.listing(listing)})
  end

  def create(conn, params) do
    attrs = Map.get(params, "listing", params)

    # Validate first so malformed requests don't burn the poster's quota.
    with {:ok, _} <- Listings.validate_listing(attrs),
         :ok <- limit(:post, conn),
         {:ok, listing, token} <- Listings.create_listing(attrs) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", Serializer.listing(listing).url)
      |> json(Serializer.created(listing, token))
    end
  end

  def update(conn, %{"id" => id} = params) do
    attrs = Map.get(params, "listing", Map.delete(params, "id"))

    # Authorize and validate before charging, so bad tokens or bad input
    # never burn the shared edit quota.
    with {:ok, listing} <- fetch_owned(conn, id),
         {:ok, _} <- Listings.validate_update(listing, attrs),
         :ok <- limit(:edit, conn),
         {:ok, listing} <- Listings.update_listing(listing, attrs) do
      json(conn, %{listing: Serializer.listing(listing)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, listing} <- fetch_owned(conn, id),
         :ok <- limit(:edit, conn),
         {:ok, _} <- Listings.delete_listing(listing) do
      json(conn, %{deleted: true, id: listing.id})
    end
  end

  def flag(conn, %{"id" => id}) do
    with {:ok, listing} <- fetch(id),
         :ok <- limit(:flag, conn),
         {:ok, result} <- Listings.flag_listing(listing, ClientIP.flag_key(conn)) do
      json(conn, %{flagged: true, id: listing.id, already_flagged: result == :already_flagged})
    end
  end

  def stats(conn, _params), do: json(conn, Listings.stats())

  ## Shared helpers (also used by ReplyController)

  def fetch(id) do
    case Listings.get_listing(id) do
      nil -> {:error, :not_found}
      listing -> {:ok, listing}
    end
  end

  @doc """
  Owner access. Deliberately bypasses the flag filter so a hidden listing's
  owner can still read replies, edit, or delete it.
  """
  def fetch_owned(conn, id) do
    case Listings.get_listing_for_owner(id) do
      nil ->
        {:error, :not_found}

      listing ->
        if Listings.verify_token(listing, bearer(conn)),
          do: {:ok, listing},
          else: {:error, :unauthorized}
    end
  end

  def limit(bucket, conn) do
    case RateLimiter.check(bucket, ClientIP.get(conn)) do
      :ok -> :ok
      {:error, retry} -> {:error, {:rate_limited, retry}}
    end
  end

  # Header only: tokens in query strings end up in access logs.
  defp bearer(conn) do
    with [header | _] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         "bearer" <- String.downcase(scheme) do
      String.trim(token)
    else
      _ -> nil
    end
  end

  defp next_cursor(listings, opts) do
    if listings != [] and length(listings) >= Listings.page_size(opts), do: List.last(listings).id
  end
end
