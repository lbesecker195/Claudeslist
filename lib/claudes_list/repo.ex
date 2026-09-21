defmodule ClaudesList.Repo do
  use Ecto.Repo,
    otp_app: :claudes_list,
    adapter: Ecto.Adapters.Postgres
end
