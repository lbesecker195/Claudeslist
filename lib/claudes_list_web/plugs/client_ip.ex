defmodule ClaudesListWeb.ClientIP do
  @moduledoc """
  Rate-limit key for a request.

  Behind a reverse proxy every request arrives from the proxy's address, so
  set `CLIENT_IP_HEADER` (e.g. `x-real-ip`) to a header the proxy
  *overwrites* with the peer address. Never point it at a header the proxy
  appends to (like a raw `x-forwarded-for`), or clients can spoof it.
  Unset, the socket peer address is used.

  The returned value is a *client key*, not a raw address: IPv6 addresses
  are collapsed to their /64 (a single subscriber usually controls a whole
  /64) and IPv4-mapped IPv6 addresses to plain IPv4, so rotating addresses
  inside one allocation does not mint fresh rate-limit buckets.
  """

  import Bitwise

  def header, do: Application.get_env(:claudes_list, :client_ip_header)

  @doc "Rate-limit key for a request: IPv4 address or IPv6 /64."
  def get(%Plug.Conn{} = conn), do: conn |> address() |> key()

  @doc "Coarser key for flags: IPv4 /24 or IPv6 /48 (one vote per network)."
  def flag_key(%Plug.Conn{} = conn), do: conn |> address() |> flag_key()
  def flag_key(addr) when is_tuple(addr), do: addr |> unmap() |> mask(24, 48)

  def flag_key(addr) when is_binary(addr) do
    case parse(addr) do
      {:ok, tuple} -> flag_key(tuple)
      :error -> addr
    end
  end

  @doc """
  Parsed client address: the configured header when it holds a valid IP,
  otherwise the socket peer. Garbage in the header is ignored, never used.
  """
  def address(%Plug.Conn{} = conn) do
    with value when is_binary(value) <- from_header(header(), &Plug.Conn.get_req_header(conn, &1)),
         {:ok, tuple} <- parse(value) do
      tuple
    else
      _ -> conn.remote_ip
    end
  end

  @doc "Normalizes an address (tuple or string) into a rate-limit client key."
  def key(addr) when is_tuple(addr), do: addr |> unmap() |> mask(32, 64)

  def key(addr) when is_binary(addr) do
    case parse(addr) do
      {:ok, tuple} -> key(tuple)
      :error -> "invalid"
    end
  end

  @doc false
  def parse(value) when is_binary(value) and byte_size(value) <= 45 do
    case :inet.parse_strict_address(:binary.bin_to_list(value)) do
      {:ok, tuple} -> {:ok, tuple}
      {:error, _} -> :error
    end
  end

  def parse(_), do: :error

  defp unmap({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}
  defp unmap(addr), do: addr

  defp mask({_, _, _, _} = v4, 32, _), do: to_string(:inet.ntoa(v4))
  defp mask({a, b, c, _}, 24, _), do: to_string(:inet.ntoa({a, b, c, 0})) <> "/24"

  defp mask({a, b, c, d, _, _, _, _}, _, 64),
    do: to_string(:inet.ntoa({a, b, c, d, 0, 0, 0, 0})) <> "/64"

  defp mask({a, b, c, _, _, _, _, _}, _, 48),
    do: to_string(:inet.ntoa({a, b, c, 0, 0, 0, 0, 0})) <> "/48"

  @doc false
  def from_header(nil, _lookup), do: nil

  def from_header(name, lookup) do
    case lookup.(name) do
      [value | _] -> value |> String.split(",") |> hd() |> String.trim() |> blank_to_nil()
      _ -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v
end

defmodule ClaudesListWeb.ClientIP.Socket do
  @moduledoc """
  Client IP for a LiveView socket. `:x_headers` connect_info only carries
  `x-*` headers, so the configured header must start with `x-`.
  """
  import Phoenix.LiveView, only: [get_connect_info: 2, connected?: 1]

  alias ClaudesListWeb.ClientIP

  @doc "Rate-limit key for the socket (\"unknown\" before it connects)."
  def rate_key(socket), do: socket |> get() |> elem_or(0)

  @doc "Flag key for the socket (\"unknown\" before it connects)."
  def flag_key(socket), do: socket |> get() |> elem_or(1)

  defp elem_or(nil, _), do: "unknown"
  defp elem_or(pair, i), do: elem(pair, i)

  @doc "`{rate_limit_key, flag_key}` for a connected socket, else nil."
  def get(socket) do
    if connected?(socket) do
      headers = get_connect_info(socket, :x_headers) || []
      lookup = fn name -> for {k, v} <- headers, String.downcase(k) == name, do: v end

      peer = get_in(get_connect_info(socket, :peer_data) || %{}, [:address])

      header_addr =
        with value when is_binary(value) <- ClientIP.from_header(ClientIP.header(), lookup),
             {:ok, tuple} <- ClientIP.parse(value),
             do: tuple,
             else: (_ -> nil)

      case header_addr || peer do
        nil -> nil
        addr -> {ClientIP.key(addr), ClientIP.flag_key(addr)}
      end
    end
  end
end
