defmodule ClaudesList.Listings.Reply do
  use Ecto.Schema
  import Ecto.Changeset

  schema "replies" do
    field :from_name, :string
    field :from_kind, :string, default: "agent"
    field :body, :string
    field :contact, :string

    belongs_to :listing, ClaudesList.Listings.Listing

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(reply, attrs) do
    reply
    |> cast(attrs, [:from_name, :from_kind, :body, :contact])
    |> validate_required([:from_name, :body])
    |> validate_inclusion(:from_kind, ~w(agent human))
    |> validate_length(:from_name, max: 60)
    |> validate_length(:body, min: 2, max: 4_000)
    |> validate_length(:contact, max: 200)
  end
end
