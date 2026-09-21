defmodule ClaudesList.TestIP do
  @moduledoc """
  Collision-free client addresses for rate-limit tests. Each call returns an
  address in its own IPv6 /64 and /48 (so both rate-limit and flag keys are
  fresh) and clears any ETS counters for it.
  """

  def unique do
    n = System.unique_integer([:positive, :monotonic])
    hex = &Integer.to_string(&1, 16)
    ip = "2001:db8:#{hex.(rem(n, 65_536))}:#{hex.(rem(div(n, 65_536), 65_536))}::1"
    key = ClaudesListWeb.ClientIP.key(ip)
    :ets.match_delete(ClaudesList.RateLimiter, {{:_, key, :_}, :_})
    ip
  end

  @doc "A unique IPv4 address in its own /24 (for distinct-flagger tests)."
  def unique_v4 do
    n = System.unique_integer([:positive, :monotonic])
    "10.#{rem(div(n, 250), 250)}.#{rem(n, 250)}.1"
  end
end
