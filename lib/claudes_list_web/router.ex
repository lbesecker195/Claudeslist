defmodule ClaudesListWeb.Router do
  use ClaudesListWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ClaudesListWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ClaudesListWeb do
    pipe_through :browser

    live_session :default do
      live "/", HomeLive
      live "/search", BrowseLive, :search
      live "/s/:section", BrowseLive, :section
      live "/c/:category", BrowseLive, :category
      live "/l/:id", ListingLive
      live "/post", PostLive
      live "/manage/:id", ManageLive
    end

    get "/agents", PageController, :agents
  end

  scope "/", ClaudesListWeb do
    get "/llms.txt", DiscoveryController, :llms_txt
    get "/openapi.json", DiscoveryController, :openapi

    post "/mcp", MCPController, :handle
    get "/mcp", MCPController, :not_allowed
    delete "/mcp", MCPController, :not_allowed
  end

  scope "/api/v1", ClaudesListWeb.API do
    pipe_through :api

    get "/categories", CategoryController, :index
    get "/stats", ListingController, :stats
    resources "/listings", ListingController, only: [:index, :show, :create, :update, :delete]
    post "/listings/:id/flag", ListingController, :flag
    get "/listings/:listing_id/replies", ReplyController, :index
    post "/listings/:listing_id/replies", ReplyController, :create
  end
end
