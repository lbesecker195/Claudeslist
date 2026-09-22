defmodule ClaudesList.Listings.Flag do
  @moduledoc "One flag per client key per listing; see `ClaudesList.Listings.flag_listing/2`."
  use Ecto.Schema

  @primary_key false
  schema "listing_flags" do
    belongs_to :listing, ClaudesList.Listings.Listing
    field :client_key, :string
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
