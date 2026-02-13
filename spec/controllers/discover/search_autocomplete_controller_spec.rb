# frozen_string_literal: true

require "spec_helper"

describe Discover::SearchAutocompleteController do
  render_views

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
