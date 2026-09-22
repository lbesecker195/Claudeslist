defmodule ClaudesList.Analytics do
  @moduledoc """
  Fire-and-forget usage reporting to SeriouslySimpleAnalytics
  (https://seriouslysimpleanalytics.com/llms.txt).

  Agents reach ClaudesList over MCP and REST, where no browser script can
  run, so those calls are reported from here; the `wa.js` tag in the root
  layout covers human pageviews. Both halves use the same account and land
  in one dashboard, separated by `project`.

  Ground rules, deliberately narrower than the service allows:

    * Never blocks a request: every ping runs in a supervised task with a
      short timeout, no retry, and no error surfaced to the caller.
    * Sends no listing content, titles, bodies, contacts, edit tokens,
      names, or IP addresses. Only category slugs, tool names, outcomes,
      and timings.
    * Sends no `email` and no `c`/`cc`/`s_p`/`n` location. We don't know
      where an agent's operator is, and inventing a location would put
      wrong data in the reports.
  """

  require Logger

  @default_endpoint "https://seriouslysimpleanalytics.com/api/ping"
  @max_value_length 64
  @max_extra_params 20
  @timeout 2_000

  @doc "Reports one event. Always returns `:ok`, even when disabled or failing."
  def track(event, params \\ []) do
    if enabled?() do
      url = build_url(event, params)

      Task.Supervisor.start_child(ClaudesList.TaskSupervisor, fn -> send_ping(url) end)
    end

    :ok
  end

  @doc """
  Times `fun` and reports `event` with `latency_ms` and `outcome`.
  The result of `fun` is returned untouched, and an exception is reported
  as `outcome=error` before being re-raised.
  """
  def track_timed(event, params, fun) do
    started = System.monotonic_time(:millisecond)

    try do
      result = fun.()
      report(event, params, started, outcome(result))
      result
    rescue
      exception ->
        report(event, params, started, "error")
        reraise(exception, __STACKTRACE__)
    end
  end

  defp report(event, params, started, outcome) do
    track(
      event,
      params ++ [latency_ms: System.monotonic_time(:millisecond) - started, outcome: outcome]
    )
  end

  defp outcome({:error, _}), do: "error"
  defp outcome(%{isError: true}), do: "error"
  defp outcome(_), do: "success"

  def enabled?, do: Keyword.get(config(), :enabled, false) and is_binary(uid())

  defp config, do: Application.get_env(:claudes_list, __MODULE__, [])
  defp uid, do: Keyword.get(config(), :uid)
  defp project, do: Keyword.get(config(), :project, "claudeslist")
  defp endpoint, do: Keyword.get(config(), :endpoint, @default_endpoint)

  @doc "The account id for the browser tag, or nil when reporting is off."
  def site_id, do: if(enabled?(), do: uid())

  @doc false
  def build_url(event, params \\ []) do
    query =
      [uid: uid(), type: "ai", project: project(), event: to_string(event)]
      |> Kernel.++(sanitize(params))
      |> URI.encode_query()

    endpoint() <> "?" <> query
  end

  # Scalars only, truncated: everything here ends up in a URL, and URLs
  # end up in proxy logs.
  defp sanitize(params) do
    params
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Enum.map(fn {k, v} -> {k, v |> to_string() |> String.slice(0, @max_value_length)} end)
    |> Enum.take(@max_extra_params)
  end

  defp send_ping(url) do
    request = {String.to_charlist(url), []}
    http_opts = [timeout: @timeout, connect_timeout: @timeout, ssl: ssl_opts()]

    case :httpc.request(:get, request, http_opts, body_format: :binary) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.debug("analytics ping failed: #{inspect(reason)}")
    end
  catch
    kind, reason -> Logger.debug("analytics ping crashed: #{inspect({kind, reason})}")
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end
end
