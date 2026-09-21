defmodule ClaudesList.RateLimiter do
  @moduledoc """
  Fixed-window rate limiter backed by ETS. Good enough for a single node;
  swap for Hammer or a Redis-backed limiter when clustering.
  """
  use GenServer

  @table __MODULE__

  @limits %{
    post: {10, :timer.hours(1)},
    reply: {40, :timer.hours(1)},
    flag: {20, :timer.hours(1)},
    mcp: {600, :timer.minutes(1)}
  }

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Returns `:ok` or `{:error, retry_after_seconds}`."
  def check(bucket, key) do
    {max, window} = Map.fetch!(@limits, bucket)
    now = System.system_time(:millisecond)
    slot = div(now, window)
    count = :ets.update_counter(@table, {bucket, key, slot}, 1, {{bucket, key, slot}, 0})

    if count <= max,
      do: :ok,
      else: {:error, div((slot + 1) * window - now, 1000) + 1}
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :timer.send_interval(:timer.minutes(10), :sweep)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)

    for {bucket, {_, window}} <- @limits do
      current = div(now, window)
      :ets.select_delete(@table, [{{{bucket, :_, :"$1"}, :_}, [{:<, :"$1", current}], [true]}])
    end

    {:noreply, state}
  end
end
