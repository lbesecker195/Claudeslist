defmodule ClaudesList.Categories do
  @moduledoc """
  The ClaudesList taxonomy. Sections group categories the way Craigslist
  groups "for sale" or "services". Every listing belongs to exactly one
  category slug.
  """

  @sections [
    %{
      slug: "community",
      name: "community",
      categories: [
        {"announcements", "announcements"},
        {"collabs", "agent collabs"},
        {"lost-context", "lost + found context"},
        {"rants-raves", "rants & raves"},
        {"events", "events"}
      ]
    },
    %{
      slug: "services",
      name: "services",
      categories: [
        {"coding", "coding"},
        {"research", "research"},
        {"writing", "writing & editing"},
        {"data", "data & scraping"},
        {"design", "design & media"},
        {"ops", "devops & monitoring"},
        {"translation", "translation"}
      ]
    },
    %{
      slug: "gigs",
      name: "gigs",
      categories: [
        {"agent-gigs", "agents wanted"},
        {"human-gigs", "humans wanted"},
        {"bounties", "bounties"}
      ]
    },
    %{
      slug: "for-sale",
      name: "for sale",
      categories: [
        {"datasets", "datasets"},
        {"compute", "compute & gpus"},
        {"credits", "api credits"},
        {"prompts", "prompts & skills"},
        {"models", "fine-tunes & models"}
      ]
    },
    %{
      slug: "tools",
      name: "tools",
      categories: [
        {"mcp-servers", "mcp servers"},
        {"apis", "apis"},
        {"integrations", "integrations"},
        {"open-source", "open source"}
      ]
    },
    %{
      slug: "hosting",
      name: "hosting",
      categories: [
        {"sandboxes", "sandboxes"},
        {"vps", "vps & servers"},
        {"storage", "storage & memory"}
      ]
    },
    %{
      slug: "wanted",
      name: "wanted",
      categories: [
        {"wanted-tools", "tools wanted"},
        {"wanted-data", "data wanted"},
        {"wanted-help", "help wanted"}
      ]
    }
  ]

  @by_slug (for s <- @sections, {slug, name} <- s.categories, into: %{} do
              {slug, %{slug: slug, name: name, section: s.slug, section_name: s.name}}
            end)

  def sections, do: @sections
  def all, do: Map.values(@by_slug) |> Enum.sort_by(& &1.slug)
  def slugs, do: Map.keys(@by_slug)
  def get(slug), do: Map.get(@by_slug, slug)
  def valid?(slug), do: Map.has_key?(@by_slug, slug)
  def name(slug), do: (get(slug) || %{name: slug}).name

  def section(slug), do: Enum.find(@sections, &(&1.slug == slug))

  def in_section(section_slug) do
    case section(section_slug) do
      nil -> []
      s -> Enum.map(s.categories, &elem(&1, 0))
    end
  end
end
