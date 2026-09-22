defmodule ClaudesList.AnalyticsTest do
  # Mutates application env, so not async.
  use ExUnit.Case, async: false

  alias ClaudesList.Analytics

  setup do
    original = Application.get_env(:claudes_list, Analytics)
    on_exit(fn -> Application.put_env(:claudes_list, Analytics, original) end)

    enable = fn opts ->
      Application.put_env(
        :claudes_list,
        Analytics,
        Keyword.merge([enabled: true, uid: "acct_test", project: "claudeslist"], opts)
      )
    end

    %{enable: enable}
  end

  test "reporting is off by default in test" do
    refute Analytics.enabled?()
    refute Analytics.site_id()
    assert Analytics.track("listing_posted", category: "coding") == :ok
  end

  test "an enabled account exposes its id for the browser tag", %{enable: enable} do
    enable.([])
    assert Analytics.site_id() == "acct_test"
  end

  test "a configured account with reporting off stays off", %{enable: enable} do
    enable.(enabled: false)
    refute Analytics.enabled?()
    refute Analytics.site_id()
  end

  test "builds a ping URL with account, project and event", %{enable: enable} do
    enable.([])

    %{query: query, host: host, path: path} =
      URI.parse(Analytics.build_url("tool_called", tool: "search_listings"))

    params = URI.decode_query(query)

    assert host == "seriouslysimpleanalytics.com"
    assert path == "/api/ping"

    assert %{
             "uid" => "acct_test",
             "project" => "claudeslist",
             "type" => "ai",
             "event" => "tool_called",
             "tool" => "search_listings"
           } = params

    # Never sent: we have neither, and guessing would poison the reports.
    refute Map.has_key?(params, "email")
    refute Map.has_key?(params, "c")
    refute Map.has_key?(params, "n")
  end

  test "drops empty values, truncates long ones, and caps the parameter count", %{enable: enable} do
    enable.([])

    params =
      Analytics.build_url("error",
        kind: "boom",
        empty: "",
        missing: nil,
        long: String.duplicate("x", 500)
      )
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()

    assert params["kind"] == "boom"
    refute Map.has_key?(params, "empty")
    refute Map.has_key?(params, "missing")
    assert String.length(params["long"]) == 64

    many = for i <- 1..40, do: {:"p#{i}", i}

    built =
      Analytics.build_url("x", many) |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    # 4 fixed params (uid, type, project, event) + at most 20 extras
    assert map_size(built) <= 24
  end

  test "values with spaces and symbols are encoded, not injected", %{enable: enable} do
    enable.([])
    url = Analytics.build_url("tool_called", tool: "a b&uid=evil#frag")
    assert URI.parse(url).query |> URI.decode_query() |> Map.fetch!("tool") == "a b&uid=evil#frag"
    assert URI.decode_query(URI.parse(url).query)["uid"] == "acct_test"
  end

  test "track_timed returns the result and never swallows raises", %{enable: enable} do
    enable.(endpoint: "http://127.0.0.1:1/api/ping")

    assert Analytics.track_timed("tool_called", [tool: "t"], fn -> {:ok, 42} end) == {:ok, 42}

    assert_raise RuntimeError, "boom", fn ->
      Analytics.track_timed("tool_called", [tool: "t"], fn -> raise "boom" end)
    end
  end

  test "an unreachable collector never breaks the caller", %{enable: enable} do
    enable.(endpoint: "http://127.0.0.1:1/api/ping")
    assert Analytics.track("listing_posted", category: "coding") == :ok
    # Give the supervised task a moment to fail on its own.
    Process.sleep(100)
    assert Process.whereis(ClaudesList.TaskSupervisor) |> Process.alive?()
  end
end
