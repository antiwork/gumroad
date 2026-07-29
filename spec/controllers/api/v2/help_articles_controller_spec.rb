# frozen_string_literal: true

require "spec_helper"

describe Api::V2::HelpArticlesController do
  let(:seller) { create(:user) }
  let(:app) { create(:oauth_application, owner: create(:user)) }
  let(:token) { create("doorkeeper/access_token", application: app, resource_owner_id: seller.id, scopes: "view_public") }

  describe "GET 'index'" do
    it "returns 401 without a token" do
      get :index

      expect(response.status).to eq(401)
    end

    it "lists every article as title, description, and slug" do
      get :index, params: { access_token: token.token }

      expect(response).to be_successful
      body = response.parsed_body
      expect(body["success"]).to be(true)
      expect(body["count"]).to eq(HelpCenter::Article.count)
      entry = body["help_articles"].find { |a| a["slug"] == "124-your-gumroad-profile-page" }
      expect(entry["title"]).to be_present
      expect(entry["url"]).to end_with("/help/article/124-your-gumroad-profile-page")
      # Bodies are excluded from the listing on purpose — the caller reads the one it picks.
      expect(entry).not_to have_key("content")
    end

    it "narrows the list when a query is given" do
      get :index, params: { access_token: token.token, query: "profile page" }

      slugs = response.parsed_body["help_articles"].map { |a| a["slug"] }
      expect(slugs).to include("124-your-gumroad-profile-page")
      expect(slugs.length).to be < HelpCenter::Article.count
    end
  end

  describe "GET 'show'" do
    it "returns 401 without a token" do
      get :show, params: { slug: "124-your-gumroad-profile-page" }

      expect(response.status).to eq(401)
    end

    it "returns the article's plain text" do
      get :show, params: { access_token: token.token, slug: "124-your-gumroad-profile-page" }

      expect(response).to be_successful
      article = response.parsed_body["help_article"]
      expect(article["slug"]).to eq("124-your-gumroad-profile-page")
      expect(article["content"]).to include("Your profile allows you to have your own website on Gumroad")
      expect(article["content"]).not_to include("<p>")
    end

    # The whole point of this endpoint is answering "how does this actually work", so the theme
    # article must state that the store theme reaches product pages — the agent told a seller the
    # opposite (gumroad-private#1463) and argued with them about it.
    it "documents that the store theme applies to product pages" do
      get :show, params: { access_token: token.token, slug: "124-your-gumroad-profile-page" }

      expect(response.parsed_body["help_article"]["content"]).to include("every product page")
    end

    it "explains how to find a valid slug when the article does not exist" do
      get :show, params: { access_token: token.token, slug: "no-such-article" }

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["message"]).to include("list endpoint")
    end
  end
end
