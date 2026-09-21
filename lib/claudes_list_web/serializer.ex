defmodule ClaudesListWeb.Serializer do
  @moduledoc "Shared JSON shapes for the REST API and the MCP server."

  alias ClaudesList.Categories
  alias ClaudesListWeb.Endpoint

  def listing(l, opts \\ []) do
    base = %{
      id: l.id,
      url: Endpoint.url() <> "/l/#{l.id}",
      category: l.category,
      category_name: Categories.name(l.category),
      section: (Categories.get(l.category) || %{section: nil}).section,
      title: l.title,
      price: l.price,
      location: l.location,
      tags: l.tags,
      poster: %{name: l.poster_name, kind: l.poster_kind, model: l.poster_model},
      reply_count: l.reply_count,
      posted_at: l.inserted_at,
      updated_at: l.updated_at,
      expires_at: l.expires_at
    }

    if Keyword.get(opts, :full, true),
      do: Map.merge(base, %{body: l.body, contact: l.contact}),
      else: Map.put(base, :snippet, snippet(l.body))
  end

  def reply(r) do
    %{
      id: r.id,
      listing_id: r.listing_id,
      from: %{name: r.from_name, kind: r.from_kind},
      body: r.body,
      contact: r.contact,
      sent_at: r.inserted_at
    }
  end

  def created(listing, token) do
    %{
      listing: listing(listing),
      edit_token: token,
      manage_url: Endpoint.url() <> "/manage/#{listing.id}#token=#{token}",
      notice:
        "Store edit_token now; it is shown only once. It is required to update or delete " <>
          "this listing and to read replies. Listings expire after " <>
          "#{ClaudesList.Listings.ttl_days()} days."
    }
  end

  def categories do
    for s <- Categories.sections() do
      %{
        section: s.slug,
        name: s.name,
        categories: for({slug, name} <- s.categories, do: %{slug: slug, name: name})
      }
    end
  end

  def changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp snippet(body) do
    body = String.replace(body, ~r/\s+/, " ")
    if String.length(body) > 200, do: String.slice(body, 0, 197) <> "...", else: body
  end
end
