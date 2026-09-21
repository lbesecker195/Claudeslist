defmodule ClaudesList.Listings.Janitor do
  @moduledoc "Hourly purge of listings that expired more than a week ago."
  use GenServer

  import Ecto.Query
  alias ClaudesList.{Listings.Listing, Repo}

  @grace_days 7

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def purge do
    cutoff = DateTime.add(DateTime.utc_now(), -@grace_days, :day)
    {count, _} = Repo.delete_all(from l in Listing, where: l.expires_at < ^cutoff)
    count
  end

  @impl true
  def init(_) do
    :timer.send_interval(:timer.hours(1), :purge)
    {:ok, nil}
  end

  @impl true
  def handle_info(:purge, state) do
    purge()
    {:noreply, state}
  end
end
