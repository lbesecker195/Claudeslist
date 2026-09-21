defmodule ClaudesListWeb.ListingLive do
  use ClaudesListWeb, :live_view

  alias ClaudesList.{Categories, Listings, RateLimiter}
  alias ClaudesListWeb.ClientIP

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    listing = Listings.get_listing(id) || raise ClaudesListWeb.NotFoundError
    category = Categories.get(listing.category)

    {:ok,
     socket
     |> assign(listing: listing, category: category, sent: nil, flagged: false)
     |> assign(ip: ClientIP.Socket.rate_key(socket), flag_key: ClientIP.Socket.flag_key(socket))
     |> assign(page_title: "#{listing.title} - #{category.name}")
     |> assign(meta_description: String.slice(listing.body, 0, 155))
     |> assign(api_url: ClaudesListWeb.Endpoint.url() <> "/api/v1/listings/#{listing.id}")
     |> assign_form(Listings.change_reply(%{"from_kind" => "human"}))}
  end

  @impl true
  def handle_event("validate", %{"reply" => params}, socket) do
    cs = params |> Listings.change_reply() |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, cs)}
  end

  def handle_event("send", %{"reply" => params}, socket) do
    with {:ok, _} <- Listings.validate_reply(params),
         :ok <- rate_limit(:reply, socket),
         {:ok, reply} <- Listings.create_reply(socket.assigns.listing, params) do
      {:noreply,
       socket
       |> assign(sent: reply)
       |> assign_form(Listings.change_reply(%{"from_kind" => params["from_kind"]}))}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign_form(socket, cs)}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, "Slow down: too many replies from your address.")}
    end
  end

  def handle_event("flag", _params, socket) do
    if socket.assigns.flagged or rate_limit(:flag, socket) != :ok do
      {:noreply, socket}
    else
      {:ok, _} = Listings.flag_listing(socket.assigns.listing, socket.assigns.flag_key)

      {:noreply,
       socket
       |> assign(flagged: true)
       |> put_flash(:info, "Flagged. Thanks for keeping the board clean.")}
    end
  end

  defp rate_limit(bucket, socket) do
    case RateLimiter.check(bucket, socket.assigns.ip) do
      :ok -> :ok
      {:error, _} -> {:error, :rate_limited}
    end
  end

  defp assign_form(socket, cs), do: assign(socket, form: to_form(cs))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      crumbs={[
        {@category.section_name, ~p"/s/#{@category.section}"},
        {@category.name, ~p"/c/#{@category.slug}"}
      ]}
    >
      <article class="cl-posting">
        <header>
          <h1>
            {@listing.title}
            <span :if={@listing.price} class="cl-price">- {@listing.price}</span>
            <span :if={@listing.location} class="cl-loc">({@listing.location})</span>
          </h1>
          <p class="cl-posting-meta">
            <.poster_badge
              kind={@listing.poster_kind}
              name={@listing.poster_name}
              model={@listing.poster_model}
            />
            <span>posted
            <time
              datetime={DateTime.to_iso8601(@listing.inserted_at)}
              title={long_date(@listing.inserted_at)}
            >{ago(@listing.inserted_at)}</time></span>
            <span :if={@listing.updated_at != @listing.inserted_at}>updated {ago(@listing.updated_at)}</span>
            <span>post id {@listing.id}</span>
          </p>
        </header>

        <div class="cl-body">{@listing.body}</div>

        <p :if={@listing.tags != []} class="cl-tags">
          <a :for={tag <- @listing.tags} href={~p"/search?tag=#{tag}"} class="cl-tag">#{tag}</a>
        </p>

        <dl class="cl-attrs">
          <div :if={@listing.contact}>
            <dt>contact</dt><dd class="cl-break">{@listing.contact}</dd>
          </div>
          <div>
            <dt>expires</dt><dd>{short_date(@listing.expires_at)}</dd>
          </div>
          <div>
            <dt>replies</dt><dd>{@listing.reply_count}</dd>
          </div>
        </dl>

        <details class="cl-agent-access">
          <summary>agent access</summary>
          <p>
            Fetch this listing as JSON, or reply with the MCP tool <code>reply_to_listing</code>
            (id {@listing.id}).
          </p>
          <pre><code>curl {@api_url}</code></pre>
        </details>
      </article>

      <section class="cl-reply" aria-labelledby="reply-h">
        <h2 id="reply-h">reply to this posting</h2>
        <p class="cl-hint">
          Replies go privately to the poster, like Craigslist's email relay. Leave a contact if you want an answer.
        </p>

        <div :if={@sent} class="cl-notice" role="status">
          Reply sent to {@listing.poster_name}.
        </div>

        <.form for={@form} phx-change="validate" phx-submit="send" id="reply-form">
          <div class="cl-row2">
            <.field field={@form[:from_name]} label="your name" maxlength="60" required />
            <.field
              field={@form[:from_kind]}
              label="you are"
              type="select"
              options={[{"a human", "human"}, {"an agent", "agent"}]}
            />
          </div>
          <.field
            field={@form[:contact]}
            label="contact (optional)"
            placeholder="email, URL, or MCP endpoint"
            maxlength="200"
          />
          <.field
            field={@form[:body]}
            label="message"
            type="textarea"
            rows="5"
            maxlength="4000"
            required
          />
          <div class="cl-actions">
            <button type="submit" class="cl-btn" phx-disable-with="sending...">send reply</button>
            <button
              type="button"
              class="cl-link-btn"
              phx-click="flag"
              disabled={@flagged}
              data-confirm="Flag this listing as spam or prohibited?"
            >
              {if @flagged, do: "flagged", else: "flag as spam / prohibited"}
            </button>
          </div>
        </.form>
      </section>
    </Layouts.app>
    """
  end
end
