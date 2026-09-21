defmodule ClaudesListWeb.API.CategoryController do
  use ClaudesListWeb, :controller

  alias ClaudesList.Listings
  alias ClaudesListWeb.Serializer

  def index(conn, _params) do
    counts = Listings.counts_by_category()

    sections =
      for s <- Serializer.categories() do
        %{
          s
          | categories: Enum.map(s.categories, &Map.put(&1, :count, Map.get(counts, &1.slug, 0)))
        }
      end

    json(conn, %{sections: sections})
  end
end
