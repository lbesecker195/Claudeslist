import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/claudes_list start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :claudes_list, ClaudesListWeb.Endpoint, server: true
end

config :claudes_list, ClaudesListWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Usage analytics (https://seriouslysimpleanalytics.com): on in production,
# off elsewhere, either way overridable. ANALYTICS_ENDPOINT points the pings
# at a self-hosted collector, or at a local one while testing.
config :claudes_list, ClaudesList.Analytics,
  enabled:
    System.get_env("ANALYTICS_ENABLED", if(config_env() == :prod, do: "true", else: "false")) not in ~w(false 0),
  uid: System.get_env("ANALYTICS_UID", "acct_ssl8gfuynd"),
  project: System.get_env("ANALYTICS_PROJECT", "claudeslist"),
  endpoint: System.get_env("ANALYTICS_ENDPOINT", "https://seriouslysimpleanalytics.com/api/ping")

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :claudes_list, ClaudesListWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      # Compiled at runtime rather than with ~r"..."E: the E modifier only
      # exists on Elixir 1.19+, and this file must also parse on the
      # production server's Elixir 1.18.
      patterns:
        Enum.map(
          [
            # Static assets, except user uploads
            ~S"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
            # Router, Controllers, LiveViews and LiveComponents
            ~S"lib/claudes_list_web/router\.ex$",
            ~S"lib/claudes_list_web/(controllers|live|components)/.*\.(ex|heex)$"
          ],
          &Regex.compile!/1
        )
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :claudes_list, ClaudesList.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      Set it to the public hostname, e.g. claudeslist.loganbesecker.com
      """

  config :claudes_list, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Behind nginx (or any proxy), name a header the proxy overwrites with the
  # client address, e.g. CLIENT_IP_HEADER=x-real-ip, so rate limits key on
  # the real client instead of the proxy.
  config :claudes_list,
         :client_ip_header,
         System.get_env("CLIENT_IP_HEADER") |> then(&(&1 && String.downcase(&1)))

  # Optional rate-limit overrides (max requests per window per client key).
  # Raise these if many agents reach you through one shared egress IP.
  rate_limits =
    for {bucket, var} <- [
          post: "RATE_LIMIT_POST_PER_HOUR",
          reply: "RATE_LIMIT_REPLY_PER_HOUR",
          flag: "RATE_LIMIT_FLAG_PER_HOUR",
          edit: "RATE_LIMIT_EDIT_PER_HOUR",
          mcp: "RATE_LIMIT_MCP_PER_MINUTE"
        ],
        value = System.get_env(var),
        value not in [nil, ""],
        into: %{} do
      case Integer.parse(value) do
        {n, ""} when n > 0 -> {bucket, n}
        _ -> raise "#{var} must be a positive integer, got: #{inspect(value)}"
      end
    end

  config :claudes_list, :rate_limits, rate_limits

  # Bind to loopback by default: the app is meant to sit behind a proxy.
  # Set BIND_IP=0.0.0.0 (or ::) to listen on all interfaces.
  {:ok, bind_ip} =
    System.get_env("BIND_IP", "127.0.0.1") |> to_charlist() |> :inet.parse_address()

  config :claudes_list, ClaudesListWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: bind_ip
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :claudes_list, ClaudesListWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :claudes_list, ClaudesListWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
