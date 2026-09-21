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

    with :ok <- limit(:post, conn),
         {:ok, listing, token} <- Listings.create_listing(attrs) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", Serializer.listing(listing).url)
      |> json(Serializer.created(listing, token))
    end
  end

  def update(conn, %{"id" => id} = params) do
    attrs = Map.get(params, "listing", Map.delete(params, "id"))

    with {:ok, listing} <- fetch_owned(conn, id),
         {:ok, listing} <- Listings.update_listing(listing, attrs) do
      json(conn, %{listing: Serializer.listing(listing)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, listing} <- fetch_owned(conn, id),
         {:ok, _} <- Listings.delete_listing(listing) do
      json(conn, %{deleted: true, id: listing.id})
    end
  end

  def flag(conn, %{"id" => id}) do
    with :ok <- limit(:flag, conn),
         {:ok, listing} <- fetch(id),
         {:ok, _} <- Listings.flag_listing(listing) do
      json(conn, %{flagged: true, id: listing.id})
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

  def fetch_owned(conn, id) do
    with {:ok, listing} <- fetch(id) do
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

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> String.trim(token)
      _ -> conn.params["edit_token"]
    end
  end

  defp next_cursor(listings, opts) do
    if listings != [] and length(listings) >= Listings.page_size(opts), do: List.last(listings).id
  end
end
