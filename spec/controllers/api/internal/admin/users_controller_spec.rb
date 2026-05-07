# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::UsersController do
  let(:admin_user) { create(:admin_user) }

  shared_examples "supports user lookup by external_id" do |action, build_user: -> { create(:user) }, extra_params: {}, success_status: :ok|
    describe "external_id lookup" do
      it "looks up the user by external_id" do
        user = instance_exec(&build_user)
        post action, params: extra_params.merge(external_id: user.external_id)
        expect(response).to have_http_status(success_status)
      end

      it "returns 404 when external_id does not match any user" do
        post action, params: extra_params.merge(external_id: "999999999999")
        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
      end

      it "prefers external_id over email when both are provided" do
        target = instance_exec(&build_user)
        other = instance_exec(&build_user)
        post action, params: extra_params.merge(external_id: target.external_id, email: other.email)
        expect(response).to have_http_status(success_status)
      end
    end
  end

  describe "POST info" do
    include_examples "admin api authorization required", :post, :info

    before { stub_const("GUMROAD_ADMIN_ID", admin_user.id) }

    it "returns a bad request when email is missing" do
      post :info

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email or external_id is required" }.as_json)
    end

    it "returns not found when the user does not exist" do
      post :info, params: { email: "missing@example.com" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "returns a comprehensive info payload for a compliant seller" do
      user = create(:compliant_user, email: "seller@example.com", name: "Seller One", username: "sellerone")

      post :info, params: { email: user.email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)

      info = response.parsed_body["user"]
      expect(info).to include(
        "id" => user.external_id,
        "email" => user.form_email,
        "name" => "Seller One",
        "username" => "sellerone",
        "deleted_at" => nil,
        "active_watched_user" => nil,
        "two_factor_authentication_enabled" => false
      )
      expect(info["created_at"]).to eq(user.created_at.as_json)

      expect(info["risk_state"]).to include(
        "status" => "Compliant",
        "user_risk_state" => "compliant",
        "suspended" => false,
        "flagged_for_fraud" => false,
        "flagged_for_tos_violation" => false,
        "on_probation" => false,
        "compliant" => true,
        "last_status_changed_at" => nil
      )

      expect(info["payouts"]).to include(
        "paused_internally" => false,
        "paused_by_user" => false,
        "paused_by_source" => nil,
        "paused_for_reason" => nil
      )

      expect(info["stats"]).to include(
        "sales_count" => 0,
        "total_earnings_formatted" => "$0.00",
        "unpaid_balance_formatted" => "$0.00",
        "comments_count" => 0
      )
    end

    it "reports the suspension status and latest status timestamp for a suspended user" do
      user = create(:tos_user, email: "suspended@example.com")
      comment = create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_SUSPENDED, created_at: 2.days.ago)

      post :info, params: { email: user.email }

      info = response.parsed_body["user"]
      expect(info["risk_state"]).to include(
        "status" => "Suspended",
        "suspended" => true,
        "compliant" => false,
        "last_status_changed_at" => comment.created_at.as_json
      )
    end

    it "reflects two-factor authentication when enabled" do
      user = create(:compliant_user, email: "tfa@example.com")
      user.update!(two_factor_authentication_enabled: true)

      post :info, params: { email: user.email }

      expect(response.parsed_body["user"]["two_factor_authentication_enabled"]).to be(true)
    end

    it "surfaces the country from the alive user compliance info" do
      user = create(:compliant_user, email: "geo@example.com")
      create(:user_compliance_info, user:, country: "Germany")

      post :info, params: { email: user.email }

      expect(response.parsed_body["user"]["country"]).to eq("Germany")
    end

    it "reports admin-paused payouts with the latest pause comment as the reason" do
      user = create(:compliant_user, email: "paused@example.com")
      user.update!(payouts_paused_internally: true, payouts_paused_by: GUMROAD_ADMIN_ID)
      user.comments.create!(author_id: GUMROAD_ADMIN_ID, comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED, content: "Manual review pending")

      post :info, params: { email: user.email }

      expect(response.parsed_body["user"]["payouts"]).to include(
        "paused_internally" => true,
        "paused_by_source" => User::PAYOUT_PAUSE_SOURCE_ADMIN,
        "paused_for_reason" => "Manual review pending"
      )
    end

    it "reports system-paused payouts without exposing a paused_for_reason" do
      user = create(:compliant_user, email: "syspaused@example.com")
      user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)

      post :info, params: { email: user.email }

      expect(response.parsed_body["user"]["payouts"]).to include(
        "paused_internally" => true,
        "paused_by_source" => User::PAYOUT_PAUSE_SOURCE_SYSTEM,
        "paused_for_reason" => nil
      )
    end

    it "reports paused_by_user when the seller has self-paused via Settings" do
      user = create(:compliant_user, email: "selfpaused@example.com")
      user.update!(payouts_paused_by_user: true)

      post :info, params: { email: user.email }

      expect(response.parsed_body["user"]["payouts"]).to include(
        "paused_internally" => false,
        "paused_by_user" => true,
        "paused_by_source" => User::PAYOUT_PAUSE_SOURCE_USER
      )
    end

    it "surfaces a deactivated user with a populated deleted_at" do
      user = create(:compliant_user, email: "deactivated@example.com")
      user.deactivate!

      post :info, params: { email: user.email }

      expect(response).to have_http_status(:ok)
      info = response.parsed_body["user"]
      expect(info["id"]).to eq(user.external_id)
      expect(info["deleted_at"]).to eq(user.reload.deleted_at.as_json)
    end

    it "looks up a soft-deleted user by external_id" do
      user = create(:compliant_user, email: "deleted-by-id@example.com")
      user.mark_deleted!

      post :info, params: { external_id: user.external_id }

      expect(response).to have_http_status(:ok)
      info = response.parsed_body["user"]
      expect(info["id"]).to eq(user.external_id)
      expect(info["deleted_at"]).to eq(user.reload.deleted_at.as_json)
    end

    include_examples "supports user lookup by external_id", :info, build_user: -> { create(:compliant_user) }

    it "uses the latest risk-state comment for last_status_changed_at, including on_probation transitions" do
      user = create(:compliant_user, email: "probation@example.com")
      create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_COMPLIANT, created_at: 1.month.ago)
      probation_comment = create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_ON_PROBATION, created_at: 1.day.ago)
      user.update_column(:user_risk_state, "on_probation")

      post :info, params: { email: user.email }

      expect(response.parsed_body["user"]["risk_state"]).to include(
        "user_risk_state" => "on_probation",
        "on_probation" => true,
        "last_status_changed_at" => probation_comment.created_at.as_json
      )
    end

    it "computes sales_count and total_earnings_formatted from the seller's successful sales" do
      seller = create(:compliant_user, email: "earner@example.com")
      product = create(:product, user: seller)
      create(:free_purchase, link: product, seller:)
      create(:free_purchase, link: product, seller:)
      create(:failed_purchase, link: product, seller:)
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(1500)

      post :info, params: { email: seller.email }

      stats = response.parsed_body["user"]["stats"]
      expect(stats["sales_count"]).to eq(2)
      expect(stats["total_earnings_formatted"]).to eq("$15.00")
    end

    it "includes the active watched user" do
      user = create(:compliant_user, email: "watched@example.com")
      watched_user = create(:watched_user,
                            user:,
                            revenue_threshold_cents: 20_000,
                            revenue_cents: 12_500,
                            unpaid_balance_cents: 2_500,
                            notes: "Review again")
      watched_user.update!(last_synced_at: 1.hour.ago)

      post :info, params: { email: user.email }

      expect(response.parsed_body["user"]["active_watched_user"]).to eq(
        "id" => watched_user.external_id,
        "revenue_threshold_cents" => 20_000,
        "revenue_cents" => 12_500,
        "unpaid_balance_cents" => 2_500,
        "notes" => "Review again",
        "created_at" => watched_user.created_at.iso8601,
        "last_synced_at" => watched_user.last_synced_at.iso8601
      )
    end
  end

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
      expect(response.parsed_body).to eq({ success: false, message: "email or external_id is required" }.as_json)
    end

    it "returns not found when the user does not exist" do
      post :suspension, params: { email: "missing@example.com" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "returns not found when external_id matches a soft-deleted user" do
      user = create(:compliant_user)
      user.mark_deleted!

      post :suspension, params: { external_id: user.external_id }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    include_examples "supports user lookup by external_id", :suspension, build_user: -> { create(:compliant_user) }
  end

  describe "POST reset_password" do
    let(:user) { create(:user) }

    include_examples "admin api authorization required", :post, :reset_password

    it "returns 400 when email is missing" do
      post :reset_password

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email or external_id is required" }.as_json)
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

    it "skips the email-format check when only external_id is provided" do
      expect_any_instance_of(User).to receive(:send_reset_password_instructions)

      post :reset_password, params: { external_id: user.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({ success: true, message: "Reset password instructions sent" }.as_json)
    end

    it "skips the email-format check when external_id is provided alongside a malformed email" do
      expect_any_instance_of(User).to receive(:send_reset_password_instructions)

      post :reset_password, params: { external_id: user.external_id, email: "garbage" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({ success: true, message: "Reset password instructions sent" }.as_json)
    end

    context "with a user lookup helper stubbed" do
      before { allow_any_instance_of(User).to receive(:send_reset_password_instructions) }

      include_examples "supports user lookup by external_id", :reset_password
    end
  end

  describe "POST update_email" do
    let(:user) { create(:user) }
    let(:new_email) { "fresh@example.com" }

    include_examples "admin api authorization required", :post, :update_email

    it "returns 400 when current_email is missing" do
      post :update_email, params: { new_email: new_email }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "current_email (or external_id) and new_email are required" }.as_json)
    end

    it "returns 400 when new_email is missing" do
      post :update_email, params: { current_email: user.email }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "current_email (or external_id) and new_email are required" }.as_json)
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

    it "looks up the user by external_id and updates the email" do
      post :update_email, params: { external_id: user.external_id, new_email: new_email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(user.reload.unconfirmed_email).to eq(new_email)
    end

    it "returns 400 when neither current_email nor external_id is provided" do
      post :update_email, params: { new_email: new_email }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "current_email (or external_id) and new_email are required" }.as_json)
    end

    it "returns 404 when external_id matches a soft-deleted user" do
      user.mark_deleted!

      post :update_email, params: { external_id: user.external_id, new_email: new_email }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "prefers external_id over current_email when both are provided" do
      other_user = create(:user)

      post :update_email, params: { external_id: user.external_id, current_email: other_user.email, new_email: new_email }

      expect(response).to have_http_status(:ok)
      expect(user.reload.unconfirmed_email).to eq(new_email)
      expect(other_user.reload.unconfirmed_email).to be_nil
    end
  end

  describe "POST two_factor_authentication" do
    let(:user) { create(:user) }

    include_examples "admin api authorization required", :post, :two_factor_authentication

    it "returns 400 when email is missing" do
      post :two_factor_authentication, params: { enabled: true }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email or external_id is required" }.as_json)
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

    include_examples "supports user lookup by external_id", :two_factor_authentication, extra_params: { enabled: true }
  end

  describe "POST create_comment" do
    let(:user) { create(:user) }
    let(:idempotency_key) { SecureRandom.uuid }

    include_examples "admin api authorization required", :post, :create_comment

    before { stub_const("GUMROAD_ADMIN_ID", admin_user.id) }

    it "returns 400 when email is missing" do
      post :create_comment, params: { content: "hi", idempotency_key: idempotency_key }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email or external_id is required" }.as_json)
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

    it "creates comments and audit rows attributed to a per-actor token" do
      actor = create(:admin_user)
      plaintext_token = AdminApiToken.mint!(actor_user_id: actor.id)
      admin_api_token = AdminApiToken.find_by!(actor_user: actor, token_hash: AdminApiToken.hash_token(plaintext_token))
      request.headers["Authorization"] = "Bearer #{plaintext_token}"

      post :create_comment, params: { email: user.email, content: "Actor note", idempotency_key: idempotency_key }

      expect(response).to have_http_status(:ok)
      expect(user.comments.last).to have_attributes(
        author_id: actor.id,
        content: "Actor note"
      )
      expect(AdminApiAuditLog.last).to have_attributes(
        action: "users.create_comment",
        actor_user_id: actor.id,
        admin_api_token_id: admin_api_token.id,
        target_type: "User",
        target_id: user.id,
        response_status: 200
      )
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

    include_examples "supports user lookup by external_id", :create_comment, extra_params: { content: "via external_id", idempotency_key: SecureRandom.uuid }
  end

  describe "POST mark_compliant" do
    let(:user) { create(:user, user_risk_state: "suspended_for_fraud", email: "seller@example.com") }

    include_examples "admin api authorization required", :post, :mark_compliant

    it "returns 400 when email is missing" do
      post :mark_compliant

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email or external_id is required" }.as_json)
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

    include_examples "supports user lookup by external_id", :mark_compliant, build_user: -> { create(:user, user_risk_state: "suspended_for_fraud") }
  end

  describe "POST suspend_for_fraud" do
    let(:user) { create(:compliant_user, email: "seller@example.com") }

    include_examples "admin api authorization required", :post, :suspend_for_fraud

    it "returns 400 when email is missing" do
      post :suspend_for_fraud

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email or external_id is required" }.as_json)
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

    include_examples "supports user lookup by external_id", :suspend_for_fraud, build_user: -> { create(:compliant_user) }
  end

  describe "POST watch" do
    let(:user) { create(:user) }

    include_examples "admin api authorization required", :post, :watch

    it "returns bad request when email is missing" do
      post :watch, params: { revenue_threshold: "200" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq("email or external_id is required")
    end

    it "returns bad request when revenue_threshold is missing" do
      post :watch, params: { email: user.email }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq("revenue_threshold is required")
    end

    it "returns bad request when revenue_threshold is not positive" do
      post :watch, params: { email: user.email, revenue_threshold: "0" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq("revenue_threshold must be a positive number")
    end

    it "returns bad request when revenue_threshold is non-finite" do
      ["Infinity", "-Infinity", "NaN"].each do |revenue_threshold|
        post :watch, params: { email: user.email, revenue_threshold: }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["message"]).to eq("revenue_threshold must be a positive number")
      end
    end

    it "returns not found when user does not exist" do
      post :watch, params: { email: "missing@example.com", revenue_threshold: "200" }

      expect(response).to have_http_status(:not_found)
    end

    it "creates a watched user record" do
      expect do
        post :watch, params: { email: user.email, revenue_threshold: "200", notes: "Risk review: monitoring" }
      end.to change { WatchedUser.count }.by(1)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["success"]).to be(true)
      expect(body["message"]).to eq("User added to watchlist")
      expect(body["watched_user"]["revenue_threshold_cents"]).to eq(20_000)
      expect(body["watched_user"]["notes"]).to eq("Risk review: monitoring")
    end

    it "returns 422 when user is already being watched" do
      create(:watched_user, user: user)

      post :watch, params: { email: user.email, revenue_threshold: "500" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to eq("User is already being watched")
    end

    include_examples "supports user lookup by external_id", :watch, extra_params: { revenue_threshold: "200" }
  end

  describe "POST unwatch" do
    let(:user) { create(:user) }

    include_examples "admin api authorization required", :post, :unwatch

    it "returns bad request when email is missing" do
      post :unwatch

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq("email or external_id is required")
    end

    it "returns not found when user does not exist" do
      post :unwatch, params: { email: "missing@example.com" }

      expect(response).to have_http_status(:not_found)
    end

    it "removes the user from the watchlist" do
      watched_user = create(:watched_user, user: user)

      post :unwatch, params: { email: user.email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(watched_user.reload.deleted_at).not_to be_nil
    end

    it "returns 422 when user is not being watched" do
      post :unwatch, params: { email: user.email }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to eq("User is not currently being watched")
    end

    include_examples "supports user lookup by external_id", :unwatch, build_user: -> { user = create(:user); create(:watched_user, user:); user }
  end

  describe "POST update_watch" do
    let(:user) { create(:user) }

    include_examples "admin api authorization required", :post, :update_watch

    it "returns bad request when email is missing" do
      post :update_watch, params: { revenue_threshold: "200" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq("email or external_id is required")
    end

    it "returns bad request when revenue_threshold is missing" do
      post :update_watch, params: { email: user.email }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq("revenue_threshold is required")
    end

    it "returns bad request when revenue_threshold is not positive" do
      create(:watched_user, user:)

      post :update_watch, params: { email: user.email, revenue_threshold: "0" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq("revenue_threshold must be a positive number")
    end

    it "returns not found when user does not exist" do
      post :update_watch, params: { email: "missing@example.com", revenue_threshold: "200" }

      expect(response).to have_http_status(:not_found)
    end

    it "returns 422 when user is not being watched" do
      post :update_watch, params: { email: user.email, revenue_threshold: "200" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to eq("User is not currently being watched")
    end

    it "updates the active watched user" do
      watched_user = create(:watched_user, user:, revenue_threshold_cents: 20_000, notes: "Old notes")

      expect do
        post :update_watch, params: { email: user.email, revenue_threshold: "500", notes: "New notes" }
      end.not_to change { WatchedUser.count }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["message"]).to eq("Watchlist updated")
      expect(response.parsed_body["watched_user"]["revenue_threshold_cents"]).to eq(50_000)
      expect(response.parsed_body["watched_user"]["notes"]).to eq("New notes")
      expect(watched_user.reload).to have_attributes(revenue_threshold_cents: 50_000, notes: "New notes")
    end

    it "preserves notes when notes is omitted" do
      watched_user = create(:watched_user, user:, notes: "Keep this")

      post :update_watch, params: { email: user.email, revenue_threshold: "300" }

      expect(response).to have_http_status(:ok)
      expect(watched_user.reload.notes).to eq("Keep this")
    end

    it "clears notes when notes is blank" do
      watched_user = create(:watched_user, user:, notes: "Clear this")

      post :update_watch, params: { email: user.email, revenue_threshold: "300", notes: "" }

      expect(response).to have_http_status(:ok)
      expect(watched_user.reload.notes).to be_nil
    end

    include_examples "supports user lookup by external_id", :update_watch,
                     build_user: -> { user = create(:user); create(:watched_user, user:); user },
                     extra_params: { revenue_threshold: "200" }
  end
end
