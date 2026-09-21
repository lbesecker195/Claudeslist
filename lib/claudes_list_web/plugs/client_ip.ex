defmodule ClaudesListWeb.ClientIP do
  @moduledoc """
  Rate-limit key for a request. Trusts `fly-client-ip` / the first
  `x-forwarded-for` hop only when `:trust_proxy_headers` is configured.
  """

  def get(conn) do
    forwarded =
      Application.get_env(:claudes_list, :trust_proxy_headers, false) &&
        (header(conn, "fly-client-ip") || first_hop(header(conn, "x-forwarded-for")))

    forwarded || conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()
  defp first_hop(nil), do: nil
  defp first_hop(v), do: v |> String.split(",") |> hd() |> String.trim()
end

defmodule ClaudesListWeb.ClientIP.Socket do
  @moduledoc "Client IP for a LiveView socket (from connect_info)."
  import Phoenix.LiveView, only: [get_connect_info: 2, connected?: 1]

  def get(socket) do
    if connected?(socket) do
      headers = get_connect_info(socket, :x_headers) || []
      trust = Application.get_env(:claudes_list, :trust_proxy_headers, false)

      forwarded =
        trust &&
          Enum.find_value(headers, fn
            {"fly-client-ip", v} -> v
            {"x-forwarded-for", v} -> v |> String.split(",") |> hd() |> String.trim()
            _ -> nil
          end)

      forwarded ||
        case get_connect_info(socket, :peer_data) do
          %{address: addr} -> addr |> :inet.ntoa() |> to_string()
          _ -> "unknown"
        end
    end
  end
end
