# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::Users::WatchlistsController do
  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }
  let(:user) { create(:user) }

  before do
    sign_in admin_user
  end

  describe "POST 'create'" do
    it "adds the user to the watchlist with the given threshold and notes" do
      post :create, params: {
        user_external_id: user.external_id,
        watched_user: { revenue_threshold: "200", notes: "Same GUID across buyers" }
      }

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to be(true)

      watched_user = user.active_watched_user
      expect(watched_user).to be_present
      expect(watched_user.revenue_threshold_cents).to eq(20_000)
      expect(watched_user.notes).to eq("Same GUID across buyers")
      expect(watched_user.created_by).to eq(admin_user)
      expect(watched_user.last_synced_at).to be_present
    end

    it "rejects a missing or non-positive threshold" do
      post :create, params: { user_external_id: user.external_id, watched_user: { revenue_threshold: "0" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["success"]).to be(false)
      expect(user.watched_users).to be_empty
    end

    it "rejects when the user is already being watched" do
      create(:watched_user, user: user)

      post :create, params: {
        user_external_id: user.external_id,
        watched_user: { revenue_threshold: "200" }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["message"]).to include("already being watched")
    end
  end

  describe "PATCH 'update'" do
    it "updates the threshold and notes on the active watch" do
      watched_user = create(:watched_user, user: user, revenue_threshold_cents: 20_000, notes: "Old notes")

      patch :update, params: {
        user_external_id: user.external_id,
        watched_user: { revenue_threshold: "500", notes: "New notes" }
      }

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to be(true)
      expect(watched_user.reload.revenue_threshold_cents).to eq(50_000)
      expect(watched_user.notes).to eq("New notes")
    end

    it "rejects a non-positive threshold" do
      create(:watched_user, user: user)

      patch :update, params: {
        user_external_id: user.external_id,
        watched_user: { revenue_threshold: "0" }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["success"]).to be(false)
    end

    it "returns an error when the user is not currently being watched" do
      patch :update, params: {
        user_external_id: user.external_id,
        watched_user: { revenue_threshold: "500" }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["message"]).to eq("User is not currently being watched.")
    end
  end

  describe "DELETE 'destroy'" do
    it "soft-deletes the active watch" do
      watched_user = create(:watched_user, user: user)

      delete :destroy, params: { user_external_id: user.external_id }

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to be(true)
      expect(watched_user.reload).to be_deleted
    end

    it "returns an error when the user is not currently being watched" do
      delete :destroy, params: { user_external_id: user.external_id }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["message"]).to eq("User is not currently being watched.")
    end
  end
end
