defmodule ClaudesList.RateLimiter do
  @moduledoc """
  Fixed-window rate limiter backed by ETS. Good enough for a single node;
  swap for Hammer or a Redis-backed limiter when clustering.
  """
  use GenServer

  @table __MODULE__

  # {max per window, window}. Override the max counts at runtime with
  # RATE_LIMIT_{POST,REPLY,FLAG,EDIT}_PER_HOUR and RATE_LIMIT_MCP_PER_MINUTE.
  @defaults %{
    post: {10, :timer.hours(1)},
    reply: {40, :timer.hours(1)},
    flag: {20, :timer.hours(1)},
    edit: {60, :timer.hours(1)},
    mcp: {600, :timer.minutes(1)}
  }

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Current `{max, window_ms}` for a bucket, including runtime overrides."
  def limit(bucket) do
    {default_max, window} = Map.fetch!(@defaults, bucket)
    overrides = Application.get_env(:claudes_list, :rate_limits, %{})
    {Map.get(overrides, bucket, default_max), window}
  end

  @doc """
  Charges `cost` units to `key` in `bucket`. Returns `:ok` or
  `{:error, retry_after_seconds}`.
  """
  def check(bucket, key, cost \\ 1) when is_integer(cost) and cost > 0 do
    {max, window} = limit(bucket)
    now = System.system_time(:millisecond)
    slot = div(now, window)
    count = :ets.update_counter(@table, {bucket, key, slot}, cost, {{bucket, key, slot}, 0})

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

    for {bucket, {_, window}} <- @defaults do
      current = div(now, window)
      :ets.select_delete(@table, [{{{bucket, :_, :"$1"}, :_}, [{:<, :"$1", current}], [true]}])
    end

    {:noreply, state}
  end
end
