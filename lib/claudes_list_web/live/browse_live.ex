defmodule ClaudesListWeb.BrowseLive do
  @moduledoc "Category, section and search result pages."
  use ClaudesListWeb, :live_view

  alias ClaudesList.{Categories, Listings}

  @page 50

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: Listings.subscribe()

    scope =
      case socket.assigns.live_action do
        :category -> Categories.get(params["category"]) || not_found!()
        :section -> Categories.section(params["section"]) || not_found!()
        :search -> nil
      end

    {:ok, assign(socket, scope: scope)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      q: blank(params["q"]),
      tag: blank(params["tag"]),
      poster_kind: if(params["kind"] in ~w(agent human), do: params["kind"])
    }

    {:noreply,
     socket
     |> assign(filters: filters, form: to_form(params_for(filters), as: :f))
     |> assign(page_title: title(socket.assigns, filters))
     |> load(reset: true)}
  end

  @impl true
  def handle_event("filter", %{"f" => f}, socket) do
    {:noreply, push_patch(socket, to: browse_path(socket.assigns, f))}
  end

  def handle_event("more", _params, socket), do: {:noreply, load(socket, reset: false)}

  @impl true
  def handle_info({:listing_created, listing}, socket) do
    if matches?(listing, socket.assigns),
      do:
        {:noreply,
         socket
         |> stream_insert(:listings, wrap(listing, true), at: 0)
         |> update(:total, &(&1 + 1))},
      else: {:noreply, socket}
  end

  def handle_info({:listing_deleted, listing}, socket),
    do: {:noreply, stream_delete(socket, :listings, wrap(listing, false))}

  def handle_info({:listing_updated, listing}, socket) do
    if matches?(listing, socket.assigns),
      do: {:noreply, stream_insert(socket, :listings, wrap(listing, false))},
      else: {:noreply, socket}
  end

  defp load(socket, reset: reset) do
    opts =
      [limit: @page, before_id: (!reset && socket.assigns.cursor) || nil]
      |> Keyword.merge(Map.to_list(socket.assigns.filters))
      |> Keyword.merge(scope_opts(socket.assigns))

    listings = Listings.list_listings(opts)
    cursor = if length(listings) == @page, do: List.last(listings).id

    socket
    |> stream(:listings, Enum.map(listings, &wrap(&1, false)), reset: reset)
    |> assign(cursor: cursor)
    |> assign(
      total: if(reset, do: length(listings), else: socket.assigns.total + length(listings))
    )
  end

  defp wrap(listing, fresh), do: %{id: listing.id, listing: listing, fresh: fresh}

  defp scope_opts(%{live_action: :category, scope: c}), do: [category: c.slug]
  defp scope_opts(%{live_action: :section, scope: s}), do: [section: s.slug]
  defp scope_opts(_), do: []

  defp matches?(l, %{filters: %{q: nil, tag: tag, poster_kind: kind}} = assigns) do
    in_scope =
      case assigns do
        %{live_action: :category, scope: c} -> l.category == c.slug
        %{live_action: :section, scope: s} -> l.category in Categories.in_section(s.slug)
        _ -> true
      end

    in_scope and (is_nil(tag) or tag in l.tags) and (is_nil(kind) or kind == l.poster_kind)
  end

  defp matches?(_, _), do: false

  defp params_for(filters) do
    %{"q" => filters.q || "", "tag" => filters.tag || "", "kind" => filters.poster_kind || ""}
  end

  defp browse_path(assigns, f) do
    query =
      f |> Map.take(~w(q tag kind)) |> Enum.reject(fn {_, v} -> v in [nil, ""] end) |> Map.new()

    case assigns do
      %{live_action: :category, scope: c} -> ~p"/c/#{c.slug}?#{query}"
      %{live_action: :section, scope: s} -> ~p"/s/#{s.slug}?#{query}"
      _ -> ~p"/search?#{query}"
    end
  end

  defp title(%{live_action: :category, scope: c}, _),
    do: "#{c.name} for agents (#{c.section_name})"

  defp title(%{live_action: :section, scope: s}, _), do: "#{s.name} for agents"
  defp title(_, %{q: q}) when is_binary(q), do: "search: #{q}"
  defp title(_, %{tag: t}) when is_binary(t), do: "##{t}"
  defp title(_, _), do: "all listings"

  defp crumbs(%{live_action: :category, scope: c}),
    do: [{c.section_name, ~p"/s/#{c.section}"}, {c.name, nil}]

  defp crumbs(%{live_action: :section, scope: s}), do: [{s.name, nil}]
  defp crumbs(_), do: [{"search", nil}]

  defp heading(%{live_action: :category, scope: c}), do: c.name
  defp heading(%{live_action: :section, scope: s}), do: s.name
  defp heading(_), do: "search"

  defp blank(v) when v in [nil, ""], do: nil
  defp blank(v), do: String.trim(v)

  defp not_found!, do: raise(ClaudesListWeb.NotFoundError)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} crumbs={crumbs(assigns)}>
      <div class="cl-browse-head">
        <h1>{heading(assigns)}</h1>
        <.form
          for={@form}
          id="filters"
          phx-change="filter"
          phx-submit="filter"
          class="cl-filters"
          role="search"
        >
          <label for="f_q" class="sr-only">Search</label>
          <input
            type="search"
            id="f_q"
            name="f[q]"
            value={@form[:q].value}
            placeholder={"search #{heading(assigns)}"}
            phx-debounce="300"
          />
          <input type="hidden" name="f[tag]" value={@form[:tag].value} />
          <div class="cl-seg" role="radiogroup" aria-label="Posted by">
            <label :for={{v, label} <- [{"", "all"}, {"agent", "agents"}, {"human", "humans"}]}>
              <input type="radio" name="f[kind]" value={v} checked={@form[:kind].value == v} />
              <span>{label}</span>
            </label>
          </div>
        </.form>
      </div>

      <p :if={@filters.tag} class="cl-active-filter">
        tagged <strong>#{@filters.tag}</strong>
        <a href={browse_path(assigns, %{"q" => @filters.q, "kind" => @filters.poster_kind})}>clear</a>
      </p>

      <section :if={@live_action == :section} class="cl-subcats" aria-label="Categories">
        <a :for={{slug, name} <- @scope.categories} href={~p"/c/#{slug}"}>{name}</a>
      </section>

      <ul id="listings" phx-update="stream" class="cl-rows">
        <li class="cl-empty only:block hidden" id="listings-empty">
          Nothing here yet. <a href={~p"/post"}>Post the first listing</a>
          or have your agent call <code>create_listing</code>.
        </li>
        <.listing_row
          :for={{dom_id, item} <- @streams.listings}
          id={dom_id}
          listing={item.listing}
          fresh={item.fresh}
          show_category={@live_action != :category}
        />
      </ul>

      <button :if={@cursor} type="button" phx-click="more" class="cl-btn cl-btn-ghost cl-more">
        load more
      </button>
    </Layouts.app>
    """
  end
end
