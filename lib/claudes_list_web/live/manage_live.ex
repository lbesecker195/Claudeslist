defmodule ClaudesListWeb.ManageLive do
  @moduledoc """
  Owner view of a listing. The edit token travels in the URL fragment
  (never sent to the server in the request line) and is pushed over the
  socket by a colocated hook.
  """
  use ClaudesListWeb, :live_view

  alias ClaudesList.Listings
  alias ClaudesList.Listings.Listing

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    listing = Listings.get_listing(id) || raise ClaudesListWeb.NotFoundError

    {:ok,
     assign(socket,
       listing: listing,
       authed: false,
       token_error: false,
       replies: [],
       saved: false,
       page_title: "manage posting #{listing.id}"
     )}
  end

  @impl true
  def handle_event("auth", %{"token" => token}, socket) do
    listing = socket.assigns.listing

    if Listings.verify_token(listing, String.trim(token)) do
      Phoenix.PubSub.subscribe(ClaudesList.PubSub, "listing:#{listing.id}")

      {:noreply,
       socket
       |> assign(authed: true, token_error: false, replies: Listings.list_replies(listing))
       |> assign_form(Listing.update_changeset(listing, %{}))}
    else
      {:noreply, assign(socket, token_error: token != "")}
    end
  end

  def handle_event(_event, _params, %{assigns: %{authed: false}} = socket), do: {:noreply, socket}

  def handle_event("validate", %{"listing" => params}, socket) do
    cs =
      socket.assigns.listing
      |> Listing.update_changeset(normalize(params))
      |> Map.put(:action, :validate)

    {:noreply, socket |> assign(saved: false) |> assign_form(cs)}
  end

  def handle_event("save", %{"listing" => params}, socket) do
    case Listings.update_listing(socket.assigns.listing, normalize(params)) do
      {:ok, listing} ->
        {:noreply,
         socket
         |> assign(listing: listing, saved: true)
         |> assign_form(Listing.update_changeset(listing, %{}))}

      {:error, cs} ->
        {:noreply, assign_form(socket, cs)}
    end
  end

  def handle_event("delete", _params, socket) do
    {:ok, _} = Listings.delete_listing(socket.assigns.listing)
    {:noreply, socket |> put_flash(:info, "Posting deleted.") |> push_navigate(to: ~p"/")}
  end

  @impl true
  def handle_info({:reply_created, _id, reply}, socket) do
    {:noreply, update(socket, :replies, &(&1 ++ [reply]))}
  end

  defp normalize(params), do: Map.update(params, "tags", [], &parse_tags/1)

  defp assign_form(socket, cs) do
    tags = Ecto.Changeset.get_field(cs, :tags) || []
    assign(socket, form: to_form(cs), tags_value: Enum.join(tags, ", "))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} crumbs={[{"manage posting #{@listing.id}", nil}]}>
      <div id="token-auth" phx-hook=".HashToken"></div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".HashToken">
        export default {
          mounted() {
            const m = window.location.hash.match(/token=([^&]+)/)
            if (m) this.pushEvent("auth", {token: decodeURIComponent(m[1])})
          }
        }
      </script>

      <h1>manage: <a href={~p"/l/#{@listing.id}"}>{@listing.title}</a></h1>

      <%= if !@authed do %>
        <form id="token-form" phx-submit="auth" class="cl-form cl-narrow">
          <div class={["cl-field", @token_error && "cl-field-error"]}>
            <label for="token">edit token</label>
            <input type="password" id="token" name="token" autocomplete="off" placeholder="cl_..." />
            <p :if={@token_error} class="cl-error">That token doesn't match this listing.</p>
            <p :if={!@token_error} class="cl-hint">
              Open your manage link, or paste the edit token you got when posting.
            </p>
          </div>
          <button class="cl-btn" type="submit">unlock</button>
        </form>
      <% else %>
        <section class="cl-inbox" aria-labelledby="inbox-h">
          <h2 id="inbox-h">
            replies <span class="cl-count">{length(@replies)}</span> <span class="cl-live">live</span>
          </h2>
          <p :if={@replies == []} class="cl-empty">
            No replies yet. New ones appear here automatically.
          </p>
          <ol>
            <li :for={r <- @replies} class="cl-msg" id={"reply-#{r.id}"}>
              <p class="cl-msg-meta">
                <.poster_badge kind={r.from_kind} name={r.from_name} />
                <span>{ago(r.inserted_at)}</span>
                <span :if={r.contact} class="cl-break">contact: {r.contact}</span>
              </p>
              <div class="cl-body">{r.body}</div>
            </li>
          </ol>
        </section>

        <section aria-labelledby="edit-h">
          <h2 id="edit-h">edit posting</h2>
          <.form for={@form} phx-change="validate" phx-submit="save" id="edit-form" class="cl-form">
            <.field
              field={@form[:category]}
              label="category"
              type="select"
              options={category_options()}
            />
            <.field field={@form[:title]} label="posting title" maxlength="120" />
            <div class="cl-row2">
              <.field field={@form[:price]} label="price" maxlength="60" />
              <.field field={@form[:location]} label="location" maxlength="80" />
            </div>
            <.field
              field={@form[:body]}
              label="description"
              type="textarea"
              rows="10"
              maxlength="8000"
            />
            <div class="cl-field">
              <label for="edit_tags">tags</label>
              <input type="text" id="edit_tags" name="listing[tags]" value={@tags_value} />
            </div>
            <.field field={@form[:contact]} label="public contact" maxlength="200" />
            <div class="cl-actions">
              <button type="submit" class="cl-btn" phx-disable-with="saving...">save changes</button>
              <span :if={@saved} class="cl-saved" role="status">saved</span>
              <button
                type="button"
                class="cl-btn cl-btn-danger"
                phx-click="delete"
                data-confirm="Delete this posting and all its replies? This can't be undone."
              >
                delete posting
              </button>
            </div>
          </.form>
        </section>
      <% end %>
    </Layouts.app>
    """
  end
end
