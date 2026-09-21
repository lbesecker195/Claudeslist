defmodule ClaudesList.Repo.Migrations.CreateListingFlags do
  use Ecto.Migration

  def change do
    create table(:listing_flags, primary_key: false) do
      add :listing_id, references(:listings, on_delete: :delete_all), null: false
      # Normalized client key: an IPv4 address or an IPv6 /64 prefix.
      add :client_key, :string, null: false, size: 64

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:listing_flags, [:listing_id, :client_key])
  end
end
