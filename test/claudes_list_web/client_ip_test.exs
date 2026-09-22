defmodule ClaudesListWeb.ClientIPTest do
  # Mutates application env, so not async.
  use ClaudesListWeb.ConnCase, async: false

  alias ClaudesListWeb.ClientIP

  setup do
    limits = Application.get_env(:claudes_list, :rate_limits)

    on_exit(fn ->
      Application.delete_env(:claudes_list, :client_ip_header)
      Application.put_env(:claudes_list, :rate_limits, limits)
    end)
  end

  describe "key/1" do
    test "collapses IPv6 to its /64 and mapped IPv4 to IPv4" do
      assert ClientIP.key("2001:db8:1:2:aaaa:bbbb:cccc:dddd") == "2001:db8:1:2::/64"
      assert ClientIP.key("2001:db8:1:2::1") == ClientIP.key("2001:db8:1:2:ffff::9")
      refute ClientIP.key("2001:db8:1:2::1") == ClientIP.key("2001:db8:1:3::1")
      assert ClientIP.key("::ffff:203.0.113.7") == "203.0.113.7"
      assert ClientIP.key({0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107}) == "203.0.113.7"
      assert ClientIP.key("203.0.113.7") == "203.0.113.7"
      assert ClientIP.key("not-an-ip") == "invalid"
    end

    test "flag keys group IPv4 by /24 and IPv6 by /48" do
      assert ClientIP.flag_key("203.0.113.7") == "203.0.113.0/24"
      assert ClientIP.flag_key("203.0.113.7") == ClientIP.flag_key("203.0.113.200")
      assert ClientIP.flag_key("2001:db8:1:2::1") == "2001:db8:1::/48"
      assert ClientIP.flag_key("2001:db8:1:ffff::1") == ClientIP.flag_key("2001:db8:1:2::1")
      assert ClientIP.flag_key("::ffff:203.0.113.7") == "203.0.113.0/24"
    end
  end

  test "garbage in the configured header falls back to the peer", %{conn: conn} do
    Application.put_env(:claudes_list, :client_ip_header, "x-real-ip")
    peer = Map.put(conn, :remote_ip, {10, 1, 2, 3})

    for junk <- ["nope", String.duplicate("9", 500), <<0xFF, 0xFE>>, "1.2.3.4; DROP", "1.2.3"] do
      assert peer |> put_req_header("x-real-ip", junk) |> ClientIP.get() == "10.1.2.3"
    end
  end

  test "uses the socket peer when no header is configured", %{conn: conn} do
    conn = conn |> put_req_header("x-real-ip", "6.6.6.6") |> Map.put(:remote_ip, {10, 0, 0, 1})
    assert ClientIP.get(conn) == "10.0.0.1"
  end

  test "uses the configured header when present", %{conn: conn} do
    Application.put_env(:claudes_list, :client_ip_header, "x-real-ip")

    conn =
      conn |> put_req_header("x-real-ip", " 203.0.113.9 ") |> Map.put(:remote_ip, {127, 0, 0, 1})

    assert ClientIP.get(conn) == "203.0.113.9"
  end

  test "falls back to the peer when the configured header is missing or blank", %{conn: conn} do
    Application.put_env(:claudes_list, :client_ip_header, "x-real-ip")
    conn = Map.put(conn, :remote_ip, {127, 0, 0, 1})
    assert ClientIP.get(conn) == "127.0.0.1"
    assert conn |> put_req_header("x-real-ip", "") |> ClientIP.get() == "127.0.0.1"
  end

  test "rate limits key on the configured header", %{conn: _conn} do
    Application.put_env(:claudes_list, :client_ip_header, "x-real-ip")
    Application.put_env(:claudes_list, :rate_limits, %{post: 10})
    attrs = ClaudesList.Fixtures.listing_attrs()
    ip = ClaudesList.TestIP.unique()

    post_as = fn addr ->
      build_conn() |> put_req_header("x-real-ip", addr) |> post(~p"/api/v1/listings", attrs)
    end

    statuses = for _ <- 1..11, do: post_as.(ip).status
    assert Enum.take(statuses, 10) |> Enum.all?(&(&1 == 201))
    assert List.last(statuses) == 429
    assert post_as.(ClaudesList.TestIP.unique()).status == 201
  end
end
