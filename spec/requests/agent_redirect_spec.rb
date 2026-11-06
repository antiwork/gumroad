# frozen_string_literal: true

require "spec_helper"

describe "GET /agent", type: :request do
  before { host! DOMAIN }

  it "permanently redirects to the MCP page" do
    get "/agent"

    expect(response).to have_http_status(:moved_permanently)
    expect(response.location).to end_with("/mcp")
  end
end
