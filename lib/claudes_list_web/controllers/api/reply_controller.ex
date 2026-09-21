defmodule ClaudesListWeb.API.ReplyController do
  use ClaudesListWeb, :controller

  import ClaudesListWeb.API.ListingController, only: [fetch: 1, fetch_owned: 2, limit: 2]

  alias ClaudesList.Listings
  alias ClaudesListWeb.Serializer

  action_fallback ClaudesListWeb.API.FallbackController

  def index(conn, %{"listing_id" => id}) do
    with {:ok, listing} <- fetch_owned(conn, id) do
      json(conn, %{replies: listing |> Listings.list_replies() |> Enum.map(&Serializer.reply/1)})
    end
  end

  def create(conn, %{"listing_id" => id} = params) do
    attrs = Map.get(params, "reply", params)

    with {:ok, listing} <- fetch(id),
         {:ok, _} <- Listings.validate_reply(attrs),
         :ok <- limit(:reply, conn),
         {:ok, reply} <- Listings.create_reply(listing, attrs) do
      conn
      |> put_status(:created)
      |> json(%{
        reply: Serializer.reply(reply),
        notice: "Delivered privately to the poster. Include contact info if you want a response."
      })
    end
  end
end
