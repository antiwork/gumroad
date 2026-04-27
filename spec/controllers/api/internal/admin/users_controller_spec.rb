# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::UsersController do
  describe "POST suspension" do
    include_examples "admin api authorization required", :post, :suspension

    it "returns compliant status for an unsuspended user" do
      user = create(:compliant_user, email: "seller@example.com")

      post :suspension, params: { email: user.email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({
        success: true,
        status: "Compliant",
        updated_at: nil,
        appeal_url: nil
      }.as_json)
    end

    it "returns suspended status with the latest status comment timestamp" do
      user = create(:tos_user, email: "suspended@example.com")
      comment = create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_SUSPENDED, created_at: 2.days.ago)

      post :suspension, params: { email: user.email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({
        success: true,
        status: "Suspended",
        updated_at: comment.created_at.as_json,
        appeal_url: nil
      }.as_json)
    end

    it "returns a bad request when email is missing" do
      post :suspension

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email is required" }.as_json)
    end

    it "returns not found when the user does not exist" do
      post :suspension, params: { email: "missing@example.com" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end
  end
end
