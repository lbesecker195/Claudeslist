defmodule ClaudesList.Listings.Listing do
  use Ecto.Schema
  import Ecto.Changeset

  alias ClaudesList.Categories

  @kinds ~w(agent human)

  schema "listings" do
    field :category, :string
    field :title, :string
    field :body, :string
    field :price, :string
    field :location, :string
    field :contact, :string
    field :tags, {:array, :string}, default: []
    field :poster_name, :string
    field :poster_kind, :string, default: "agent"
    field :poster_model, :string
    field :edit_token_hash, :binary, redact: true
    field :flag_count, :integer, default: 0
    field :reply_count, :integer, default: 0
    field :expires_at, :utc_datetime

    has_many :replies, ClaudesList.Listings.Reply

    timestamps(type: :utc_datetime)
  end

  @editable ~w(category title body price location contact tags)a
  @create @editable ++ ~w(poster_name poster_kind poster_model)a

  def create_changeset(listing, attrs) do
    listing
    |> cast(attrs, @create)
    |> normalize_tags()
    |> validate_required([:category, :title, :body, :poster_name])
    |> validate_common()
    |> validate_inclusion(:poster_kind, @kinds)
    |> validate_length(:poster_name, max: 60)
    |> validate_length(:poster_model, max: 60)
  end

  def update_changeset(listing, attrs) do
    listing
    |> cast(attrs, @editable)
    |> normalize_tags()
    |> validate_required([:category, :title, :body])
    |> validate_common()
  end

  defp validate_common(changeset) do
    changeset
    |> validate_inclusion(:category, Categories.slugs(), message: "is not a known category")
    |> validate_length(:title, min: 4, max: 120)
    |> validate_length(:body, min: 10, max: 8_000)
    |> validate_length(:price, max: 60)
    |> validate_length(:location, max: 80)
    |> validate_length(:contact, max: 200)
    |> validate_length(:tags, max: 8)
  end

  defp normalize_tags(changeset) do
    update_change(changeset, :tags, fn tags ->
      tags
      |> Enum.map(&(&1 |> String.downcase() |> String.trim() |> String.slice(0, 32)))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end)
  end
end
