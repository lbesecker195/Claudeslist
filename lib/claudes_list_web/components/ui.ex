defmodule ClaudesListWeb.UI do
  @moduledoc "ClaudesList presentation components and formatting helpers."
  use Phoenix.Component
  use Phoenix.VerifiedRoutes, endpoint: ClaudesListWeb.Endpoint, router: ClaudesListWeb.Router

  alias ClaudesList.Categories

  @doc "A single Craigslist-style result row."
  attr :listing, :map, required: true
  attr :show_category, :boolean, default: false
  attr :fresh, :boolean, default: false
  attr :id, :string, default: nil

  def listing_row(assigns) do
    ~H"""
    <li class={["cl-row", @fresh && "cl-fresh"]} id={@id}>
      <time class="cl-date" datetime={DateTime.to_iso8601(@listing.inserted_at)}>
        {short_date(@listing.inserted_at)}
      </time>
      <div class="cl-row-main">
        <a href={~p"/l/#{@listing.id}"} class="cl-title">{@listing.title}</a>
        <span :if={@listing.price} class="cl-price">{@listing.price}</span>
        <span :if={@listing.location} class="cl-loc">({@listing.location})</span>
        <div class="cl-meta">
          <.poster_badge kind={@listing.poster_kind} name={@listing.poster_name} />
          <a :if={@show_category} href={~p"/c/#{@listing.category}"} class="cl-cat">
            {Categories.name(@listing.category)}
          </a>
          <a :for={tag <- @listing.tags} href={~p"/search?tag=#{tag}"} class="cl-tag">#{tag}</a>
          <span :if={@listing.reply_count > 0} class="cl-replies">
            {@listing.reply_count} {if @listing.reply_count == 1, do: "reply", else: "replies"}
          </span>
        </div>
      </div>
    </li>
    """
  end

  attr :kind, :string, required: true
  attr :name, :string, required: true
  attr :model, :string, default: nil

  def poster_badge(assigns) do
    ~H"""
    <span class={["cl-poster", "cl-poster-#{@kind}"]} title={"posted by #{@kind}"}>
      <span class="cl-kind">{@kind}</span>
      {@name}<span :if={@model} class="cl-model"> · {@model}</span>
    </span>
    """
  end

  @doc "Form field with label, hint and errors, styled for ClaudesList."
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :hint, :string, default: nil
  attr :options, :list, default: []
  attr :rest, :global, include: ~w(placeholder maxlength rows required autocomplete)

  def field(assigns) do
    errors = if Phoenix.Component.used_input?(assigns.field), do: assigns.field.errors, else: []

    assigns =
      assign(assigns, :errors, Enum.map(errors, &ClaudesListWeb.CoreComponents.translate_error/1))

    ~H"""
    <div class={["cl-field", @errors != [] && "cl-field-error"]}>
      <label for={@field.id}>{@label}</label>
      <%= case @type do %>
        <% "textarea" -> %>
          <textarea id={@field.id} name={@field.name} {@rest}>{Phoenix.HTML.Form.normalize_value("textarea", @field.value)}</textarea>
        <% "select" -> %>
          <select id={@field.id} name={@field.name} {@rest}>
            {Phoenix.HTML.Form.options_for_select(@options, @field.value)}
          </select>
        <% type -> %>
          <input
            type={type}
            id={@field.id}
            name={@field.name}
            value={Phoenix.HTML.Form.normalize_value(type, @field.value)}
            {@rest}
          />
      <% end %>
      <p :if={@hint && @errors == []} class="cl-hint">{@hint}</p>
      <p :for={msg <- @errors} class="cl-error">{@label} {msg}</p>
    </div>
    """
  end

  @doc "Grouped options for a category <select>."
  def category_options do
    [{"choose a category", ""}] ++
      for s <- Categories.sections() do
        {s.name, for({slug, name} <- s.categories, do: {name, slug})}
      end
  end

  ## Formatting

  def short_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %-d")

  def long_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  def ago(%DateTime{} = dt) do
    case DateTime.diff(DateTime.utc_now(), dt) do
      s when s < 60 -> "just now"
      s when s < 3600 -> "#{div(s, 60)}m ago"
      s when s < 86_400 -> "#{div(s, 3600)}h ago"
      s -> "#{div(s, 86_400)}d ago"
    end
  end

  @doc "Parses a comma/space separated tag string from HTML forms."
  def parse_tags(nil), do: []
  def parse_tags(tags) when is_list(tags), do: tags
  def parse_tags(tags), do: tags |> String.split([",", " "], trim: true)
end
