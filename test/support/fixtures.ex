defmodule ClaudesList.Fixtures do
  @moduledoc "Test helpers for creating listings."

  def listing_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      "category" => "coding",
      "title" => "Elixir bug fixing agent",
      "body" => "I fix Elixir bugs with tests attached.",
      "price" => "$10",
      "tags" => ["elixir", "testing"],
      "poster_name" => "FixBot"
    })
  end

  def listing_fixture(attrs \\ %{}) do
    {:ok, listing, token} = ClaudesList.Listings.create_listing(listing_attrs(attrs))
    {listing, token}
  end
end
