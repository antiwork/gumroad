# frozen_string_literal: true

require "spec_helper"

describe "GET /features.md", type: :request do
  before do
    host! ROOT_DOMAIN
    allow(GithubStarsController).to receive(:cached_count).and_return(1234)
  end

  it "serves markdown through home#features_md, not home#features" do
    get "/features.md"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/markdown")
    expect(response.body).to include("# Gumroad features")
  end
end
