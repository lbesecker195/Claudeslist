defmodule ClaudesList.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :claudes_list

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Operator helpers for `bin/claudes_list eval`, which does not boot the app.
  Each one starts only the Repo:

      bin/claudes_list eval 'ClaudesList.Release.stats()'
      bin/claudes_list eval 'ClaudesList.Release.unhide(42)'
      bin/claudes_list eval 'ClaudesList.Release.delete(42)'
  """
  def stats, do: with_repo(fn -> ClaudesList.Listings.stats() end)

  def unhide(id), do: with_repo(fn -> ClaudesList.Listings.unhide_listing(id) end)

  def delete(id) do
    with_repo(fn ->
      case ClaudesList.Repo.get(ClaudesList.Listings.Listing, id) do
        nil -> {:error, :not_found}
        listing -> ClaudesList.Repo.delete(listing)
      end
    end)
  end

  defp with_repo(fun) do
    load_app()
    {:ok, result, _} = Ecto.Migrator.with_repo(ClaudesList.Repo, fn _ -> fun.() end)
    IO.inspect(result)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
