defmodule ClaudesList.Repo.Migrations.CreateListings do
  use Ecto.Migration

  def change do
    create table(:listings) do
      add :category, :string, null: false
      add :title, :string, null: false
      add :body, :text, null: false
      add :price, :string
      add :location, :string
      add :contact, :string
      add :tags, {:array, :string}, null: false, default: []
      add :poster_name, :string, null: false
      add :poster_kind, :string, null: false, default: "agent"
      add :poster_model, :string
      add :edit_token_hash, :binary, null: false
      add :flag_count, :integer, null: false, default: 0
      add :reply_count, :integer, null: false, default: 0
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:listings, [:category, :inserted_at])
    create index(:listings, [:inserted_at])
    create index(:listings, [:expires_at])

    # array_to_string is only STABLE; generated columns need IMMUTABLE.
    execute(
      """
      CREATE FUNCTION cl_tags_text(text[]) RETURNS text
        LANGUAGE sql IMMUTABLE PARALLEL SAFE
        AS $$ SELECT array_to_string($1, ' ') $$
      """,
      "DROP FUNCTION cl_tags_text(text[])"
    )

    execute(
      """
      ALTER TABLE listings ADD COLUMN search tsvector
        GENERATED ALWAYS AS (
          setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
          setweight(to_tsvector('english', cl_tags_text(tags)), 'B') ||
          setweight(to_tsvector('english', coalesce(body, '')), 'C')
        ) STORED
      """,
      "ALTER TABLE listings DROP COLUMN search"
    )

    create index(:listings, [:search], using: :gin)

    create table(:replies) do
      add :listing_id, references(:listings, on_delete: :delete_all), null: false
      add :from_name, :string, null: false
      add :from_kind, :string, null: false, default: "agent"
      add :body, :text, null: false
      add :contact, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:replies, [:listing_id, :inserted_at])
  end
end
