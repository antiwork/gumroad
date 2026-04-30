# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::UsersController do
  let(:admin_user) { create(:admin_user) }

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

  describe "POST reset_password" do
    let(:user) { create(:user) }

    include_examples "admin api authorization required", :post, :reset_password

    it "returns 400 when email is missing" do
      post :reset_password

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email is required" }.as_json)
    end

    it "returns 400 when email is malformed" do
      post :reset_password, params: { email: "not-an-email" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "Invalid email format" }.as_json)
    end

    it "returns 404 when the user does not exist" do
      post :reset_password, params: { email: "nobody@example.com" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "sends reset password instructions and returns success" do
      expect_any_instance_of(User).to receive(:send_reset_password_instructions)

      post :reset_password, params: { email: user.email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({ success: true, message: "Reset password instructions sent" }.as_json)
    end
  end

  describe "POST update_email" do
    let(:user) { create(:user) }
    let(:new_email) { "fresh@example.com" }

    include_examples "admin api authorization required", :post, :update_email

    it "returns 400 when current_email is missing" do
      post :update_email, params: { new_email: new_email }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "Both current_email and new_email are required" }.as_json)
    end

    it "returns 400 when new_email is missing" do
      post :update_email, params: { current_email: user.email }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "Both current_email and new_email are required" }.as_json)
    end

    it "returns 400 when new_email is malformed" do
      post :update_email, params: { current_email: user.email, new_email: "not-an-email" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "Invalid new email format" }.as_json)
    end

    it "returns 404 when the current_email does not match a user" do
      post :update_email, params: { current_email: "missing@example.com", new_email: new_email }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "updates the email and returns the pending confirmation state" do
      post :update_email, params: { current_email: user.email, new_email: new_email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["message"]).to include("Email change pending confirmation")
      expect(response.parsed_body["unconfirmed_email"]).to eq(new_email)
      expect(response.parsed_body["pending_confirmation"]).to be(true)
      expect(user.reload.unconfirmed_email).to eq(new_email)
    end

    it "returns 422 when the new email collides with an existing user" do
      other_user = create(:user)

      post :update_email, params: { current_email: user.email, new_email: other_user.email }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to be(false)
    end

    it "returns 422 when the new email matches the current email" do
      post :update_email, params: { current_email: user.email, new_email: user.email }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq({ success: false, message: "New email is the same as the current email" }.as_json)
      expect(user.reload.unconfirmed_email).to be_nil
    end

    it "rejects same-email submissions case-insensitively" do
      post :update_email, params: { current_email: user.email, new_email: user.email.upcase }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to eq("New email is the same as the current email")
    end
  end

  describe "POST two_factor_authentication" do
    let(:user) { create(:user) }

    include_examples "admin api authorization required", :post, :two_factor_authentication

    it "returns 400 when email is missing" do
      post :two_factor_authentication, params: { enabled: true }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email is required" }.as_json)
    end

    it "returns 400 when enabled is missing" do
      post :two_factor_authentication, params: { email: user.email }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "enabled is required" }.as_json)
    end

    it "returns 400 when enabled is an empty string and does not modify the user" do
      user.update!(two_factor_authentication_enabled: true)
      totp_credential = TotpCredential.create!(user: user)

      post :two_factor_authentication, params: { email: user.email, enabled: "" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "enabled is required" }.as_json)
      expect(user.reload.two_factor_authentication_enabled?).to be(true)
      expect(TotpCredential.where(id: totp_credential.id)).to exist
    end

    it "treats Ruby false as a valid disable request" do
      user.update!(two_factor_authentication_enabled: true)

      post :two_factor_authentication, params: { email: user.email, enabled: false }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["two_factor_authentication_enabled"]).to be(false)
    end

    it "returns 404 when the user does not exist" do
      post :two_factor_authentication, params: { email: "missing@example.com", enabled: true }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "enables two-factor authentication" do
      user.update!(two_factor_authentication_enabled: false)

      post :two_factor_authentication, params: { email: user.email, enabled: true }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "message" => "Two-factor authentication enabled",
        "two_factor_authentication_enabled" => true
      )
      expect(user.reload.two_factor_authentication_enabled?).to be(true)
    end

    it "disables two-factor authentication and destroys the totp credential" do
      user.update!(two_factor_authentication_enabled: true)
      totp_credential = TotpCredential.create!(user: user)

      post :two_factor_authentication, params: { email: user.email, enabled: false }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "message" => "Two-factor authentication disabled",
        "two_factor_authentication_enabled" => false
      )
      expect(user.reload.two_factor_authentication_enabled?).to be(false)
      expect(TotpCredential.where(id: totp_credential.id)).to be_empty
    end
  end

  describe "POST create_comment" do
    let(:user) { create(:user) }
    let(:idempotency_key) { SecureRandom.uuid }

    include_examples "admin api authorization required", :post, :create_comment

    before { stub_const("GUMROAD_ADMIN_ID", admin_user.id) }

    it "returns 400 when email is missing" do
      post :create_comment, params: { content: "hi", idempotency_key: idempotency_key }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email is required" }.as_json)
    end

    it "returns 400 when content is missing" do
      post :create_comment, params: { email: user.email, idempotency_key: idempotency_key }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "content is required" }.as_json)
    end

    it "returns 400 when idempotency_key is missing" do
      post :create_comment, params: { email: user.email, content: "hi" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "idempotency_key is required" }.as_json)
    end

    it "returns 404 when the user does not exist" do
      post :create_comment, params: { email: "missing@example.com", content: "hi", idempotency_key: idempotency_key }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "creates a comment attributed to GUMROAD_ADMIN_ID" do
      expect do
        post :create_comment, params: { email: user.email, content: "An admin note", idempotency_key: idempotency_key }
      end.to change { user.comments.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      comment_data = response.parsed_body["comment"]
      expect(comment_data).to include("content" => "An admin note", "comment_type" => Comment::COMMENT_TYPE_NOTE)
      expect(comment_data["id"]).to be_present
      expect(user.comments.last.author_id).to eq(admin_user.id)
    end

    it "returns the existing comment when called twice with the same key and matching content" do
      post :create_comment, params: { email: user.email, content: "Note", idempotency_key: idempotency_key }
      first_id = response.parsed_body["comment"]["id"]

      expect do
        post :create_comment, params: { email: user.email, content: "Note", idempotency_key: idempotency_key }
      end.not_to change { user.comments.count }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["comment"]["id"]).to eq(first_id)
    end

    it "returns 409 conflict when the same key is reused with different content" do
      post :create_comment, params: { email: user.email, content: "First", idempotency_key: idempotency_key }
      expect(response).to have_http_status(:ok)

      post :create_comment, params: { email: user.email, content: "Different", idempotency_key: idempotency_key }

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to eq({ success: false, message: "Idempotency key already used with different content" }.as_json)
    end

    it "returns 422 when the content fails validation" do
      post :create_comment, params: { email: user.email, content: "x" * 10_001, idempotency_key: idempotency_key }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to be(false)
    end
  end

  describe "POST mark_compliant" do
    let(:user) { create(:user, user_risk_state: "suspended_for_fraud", email: "seller@example.com") }

    include_examples "admin api authorization required", :post, :mark_compliant

    before { stub_const("GUMROAD_ADMIN_ID", admin_user.id) }

    it "returns 400 when email is missing" do
      post :mark_compliant

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email is required" }.as_json)
    end

    it "returns 404 when the user does not exist" do
      post :mark_compliant, params: { email: "missing@example.com" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "marks the user compliant and creates separate audit and note comments attributed to GUMROAD_ADMIN_ID" do
      expect do
        post :mark_compliant, params: { email: user.email, note: "Cleared after review" }
      end.to change { user.comments.reload.count }.by(2)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({
        success: true,
        status: "marked_compliant",
        message: "User marked compliant"
      }.as_json)
      expect(user.reload).to be_compliant

      audit_comment = user.comments.find_by!(comment_type: Comment::COMMENT_TYPE_COMPLIANT)
      expect(audit_comment).to have_attributes(
        author_id: admin_user.id,
        comment_type: Comment::COMMENT_TYPE_COMPLIANT
      )
      expect(audit_comment.content).to include("Marked compliant by")

      note = user.comments.find_by!(comment_type: Comment::COMMENT_TYPE_NOTE)
      expect(note).to have_attributes(
        author_id: admin_user.id,
        comment_type: Comment::COMMENT_TYPE_NOTE,
        content: "Cleared after review"
      )
    end

    it "returns 422 without marking the user compliant when the note is invalid" do
      expect do
        post :mark_compliant, params: { email: user.email, note: "x" * 10_001 }
      end.not_to change { user.comments.reload.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["message"]).to include("Content is too long")
      expect(user.reload).to be_suspended_for_fraud
    end

    it "keeps the existing sibling-account compliant side effect" do
      payment_address = "shared@example.com"
      user.update!(payment_address:)
      sibling = create(:user, user_risk_state: "suspended_for_fraud", payment_address:)

      post :mark_compliant, params: { email: user.email }

      expect(response).to have_http_status(:ok)
      expect(user.reload).to be_compliant
      expect(sibling.reload).to be_compliant
      expect(sibling.comments.last).to have_attributes(
        author_name: "enable_sellers_other_accounts",
        comment_type: Comment::COMMENT_TYPE_COMPLIANT
      )
      expect(sibling.comments.last.content).to include("payment address #{payment_address} is now unblocked")
    end

    it "returns success without creating another comment when the user is already compliant" do
      user.update!(user_risk_state: "compliant")

      expect do
        post :mark_compliant, params: { email: user.email, note: "Retry" }
      end.not_to change { user.comments.reload.count }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({
        success: true,
        status: "already_compliant",
        message: "User is already compliant"
      }.as_json)
    end
  end

  describe "POST suspend_for_fraud" do
    let(:user) { create(:compliant_user, email: "seller@example.com") }

    include_examples "admin api authorization required", :post, :suspend_for_fraud

    before { stub_const("GUMROAD_ADMIN_ID", admin_user.id) }

    it "returns 400 when email is missing" do
      post :suspend_for_fraud

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email is required" }.as_json)
    end

    it "returns 404 when the user does not exist" do
      post :suspend_for_fraud, params: { email: "missing@example.com" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "suspends the user for fraud and creates an audit comment attributed to GUMROAD_ADMIN_ID" do
      expect do
        post :suspend_for_fraud, params: { email: user.email }
      end.to change { user.comments.reload.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({
        success: true,
        status: "suspended_for_fraud",
        message: "User suspended for fraud"
      }.as_json)
      expect(user.reload).to be_suspended_for_fraud

      comment = user.comments.last
      expect(comment).to have_attributes(
        author_id: admin_user.id,
        comment_type: Comment::COMMENT_TYPE_SUSPENDED
      )
      expect(comment.content).to include("Suspended for fraud")
    end

    it "creates an extra suspension note when one is provided" do
      expect do
        post :suspend_for_fraud, params: { email: user.email, suspension_note: "Chargeback risk confirmed" }
      end.to change { user.comments.reload.count }.by(2)

      expect(response).to have_http_status(:ok)
      note = user.comments.find_by!(comment_type: Comment::COMMENT_TYPE_SUSPENSION_NOTE)
      expect(note).to have_attributes(
        author_id: admin_user.id,
        comment_type: Comment::COMMENT_TYPE_SUSPENSION_NOTE,
        content: "Chargeback risk confirmed"
      )
    end

    it "returns 422 without suspending the user when the suspension note is invalid" do
      expect do
        post :suspend_for_fraud, params: { email: user.email, suspension_note: "x" * 10_001 }
      end.not_to change { user.comments.reload.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["message"]).to include("Content is too long")
      expect(user.reload).to be_compliant
    end

    it "returns success without creating another comment when the user is already suspended" do
      user.update!(user_risk_state: "suspended_for_fraud")

      expect do
        post :suspend_for_fraud, params: { email: user.email, suspension_note: "Retry" }
      end.not_to change { user.comments.reload.count }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({
        success: true,
        status: "already_suspended",
        message: "User is already suspended for fraud"
      }.as_json)
    end

    it "returns 422 when the user is suspended for a different reason" do
      user.update!(user_risk_state: "suspended_for_tos_violation")

      expect do
        post :suspend_for_fraud, params: { email: user.email }
      end.not_to change { user.comments.reload.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to be(false)
      expect(user.reload).to be_suspended_for_tos_violation
    end

    it "returns 422 when the state machine rejects the suspension" do
      user.update!(verified: true)

      post :suspend_for_fraud, params: { email: user.email }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to be(false)
      expect(user.reload).to be_compliant
    end
  end
end
