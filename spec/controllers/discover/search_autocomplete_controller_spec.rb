# frozen_string_literal: true

require "spec_helper"

describe Discover::SearchAutocompleteController do
  render_views

  describe "#search_autocomplete" do
    context "when query is blank" do
      it "returns empty array" do
        create(:product)
        index_model_records(Link)
        get :search, params: { query: "", format: :json }
        expect(response.parsed_body).to eq("products" => [], "recent_searches" => [], "viewed" => false)
      end

      it "does not store the search query" do
        expect do
          get :search, params: { query: "", format: :json }
        end.to not_change(DiscoverSearch, :count).and not_change(DiscoverSearchSuggestion, :count)
      end
    end

    context "when query is not blank" do
      it "returns products with seller name" do
        user = create(:recommendable_user, name: "Sample User")
        @product = create(:product, :recommendable, name: "Sample Product", user:)
        Link.import(refresh: true, force: true)
        get :search, params: { query: "prod", format: :json }
        expect(response.parsed_body["products"][0]).to include(
          "name" => "Sample Product",
          "url" => @product.long_url(recommended_by: "search", layout: "discover", autocomplete: "true", query: "prod"),
          "seller_name" => "Sample User",
        )
      end

      it "stores the search query along with useful metadata" do
        buyer = create(:user)
        sign_in buyer
        cookies[:_gumroad_guid] = "custom_guid"

        expect do
          get :search, params: { query: "prod", format: :json }
        end.to change(DiscoverSearch, :count).by(1).and not_change(DiscoverSearchSuggestion, :count)

        expect(DiscoverSearch.last!.attributes).to include(
          "query" => "prod",
          "user_id" => buyer.id,
          "ip_address" => "0.0.0.0",
          "browser_guid" => "custom_guid",
          "autocomplete" => true
        )
        expect(DiscoverSearch.last!.discover_search_suggestion).to be_nil
      end
    end
  end

  it "returns recent searches based on browser_guid" do
    cookies[:_gumroad_guid] = "custom_guid"

    create(:discover_search_suggestion, discover_search: create(:discover_search, browser_guid: "custom_guid", query: "recent search"))
    get :search, params: { query: "", format: :json }
    expect(response.parsed_body["recent_searches"]).to eq(["recent search"])
  end

  context "when a user is logged in" do
    let(:user) { create(:user) }

    before do
      sign_in(user)
    end

    it "returns recent searches for the user" do
      create(:discover_search_suggestion, discover_search: create(:discover_search, user:, query: "recent search"))
      get :search, params: { query: "", format: :json }
      expect(response.parsed_body["recent_searches"]).to eq(["recent search"])
    end
  end

  describe "#delete_search_suggestion" do
    let(:user) { create(:user) }
    let(:browser_guid) { "custom_guid" }

    before do
      cookies[:_gumroad_guid] = browser_guid
    end

    context "when user is logged in" do
      before do
        sign_in(user)
      end

      it "removes the search suggestion for the user" do
        suggestion = create(:discover_search_suggestion, discover_search: create(:discover_search, user: user, query: "test query"))

        expect do
          delete :delete_search_suggestion, params: { query: "test query" }
        end.to change { suggestion.reload.deleted? }.from(false).to(true)

        expect(response).to have_http_status(:no_content)
      end
    end

    context "when user is not logged in" do
      it "removes the search suggestion for the browser_guid" do
        suggestion = create(:discover_search_suggestion, discover_search: create(:discover_search, browser_guid: browser_guid, query: "test query"))

        expect do
          delete :delete_search_suggestion, params: { query: "test query" }
        end.to change { suggestion.reload.deleted? }.from(false).to(true)

        expect(response).to have_http_status(:no_content)
      end
    end

    it "does not remove search suggestions for other users or browser_guids" do
      other_user = create(:user)
      other_guid = "other_guid"

      user_suggestion = create(:discover_search_suggestion, discover_search: create(:discover_search, user: other_user, query: "test query"))
      guid_suggestion = create(:discover_search_suggestion, discover_search: create(:discover_search, browser_guid: other_guid, query: "test query"))

      delete :delete_search_suggestion, params: { query: "test query" }

      expect(user_suggestion.reload.deleted?).to be false
      expect(guid_suggestion.reload.deleted?).to be false
    end
  end
end
