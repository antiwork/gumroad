# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::PayoutsController do
  let(:user) { create(:compliant_user) }
  let(:user_id_required_message) { "user_id is required for mutating admin actions. Use /internal/admin/users/info to look up the user_id by email." }

  shared_examples "requires user_id for payout mutation" do |action, extra_params: {}|
    it "returns 400 when only email is provided" do
      post action, params: extra_params.merge(email: user.email)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: user_id_required_message }.as_json)
    end
  end

  shared_examples "checks expected_email for payout mutation" do |action, extra_params: {}|
    it "rejects mismatched expected_email without mutating payouts" do
      post action, params: extra_params.merge(user_id: user.external_id, expected_email: "other@example.com")

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to eq({ success: false, message: "expected_email does not match the user's current email" }.as_json)
    end
  end

  before do
    stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)
  end

  describe "GET index" do
    include_examples "admin api authorization required", :get, :index

    it "returns the user's recent payouts and next payout information" do
      payment1 = create(:payment_completed, user:, created_at: 1.day.ago, bank_account: create(:ach_account_stripe_succeed, user:))
      create(:payment_failed, user:, created_at: 2.days.ago)
      create(:payment, user:, created_at: 3.days.ago)
      create(:payment_completed, user:, created_at: 4.days.ago)
      payment5 = create(:payment_completed, user:, created_at: 5.days.ago, processor: PayoutProcessorType::PAYPAL, payment_address: "payme@example.com")
      payout_note = "Payout paused due to verification"
      user.add_payout_note(content: payout_note)

      allow_any_instance_of(User).to receive(:next_payout_date).and_return(Date.tomorrow)
      allow_any_instance_of(User).to receive(:formatted_balance_for_next_payout_date).and_return("$100.00")

      get :index, params: { email: user.email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["user_id"]).to eq(user.external_id)
      expect(response.parsed_body["next_payout_date"]).to eq(Date.tomorrow.to_s)
      expect(response.parsed_body["balance_for_next_payout"]).to eq("$100.00")
      expect(response.parsed_body["payout_note"]).to eq(payout_note)
      expect(response.parsed_body["pagination"]).to eq({ "next" => nil, "limit" => 20 })

      payouts = response.parsed_body["recent_payouts"]
      expect(payouts.length).to eq(5)
      expect(payouts.first).to include(
        "external_id" => payment1.external_id,
        "amount_cents" => payment1.amount_cents,
        "currency" => payment1.currency,
        "state" => payment1.state,
        "processor" => payment1.processor,
        "bank_account_visual" => "******6789",
        "paypal_email" => nil
      )
      expect(payouts.last).to include(
        "external_id" => payment5.external_id,
        "processor" => payment5.processor,
        "bank_account_visual" => nil,
        "paypal_email" => "payme@example.com"
      )
    end

    it "excludes soft-deleted payout notes from payout_note" do
      stale_note = user.add_payout_note(content: "Stripe bank sync failed: routing_number_invalid — We couldn't find the bank for that")
      current_note = user.add_payout_note(content: "Payout paused due to verification")
      stale_note.mark_deleted!

      get :index, params: { user_id: user.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["payout_note"]).to eq(current_note.content)
    end

    it "returns nil payout_note when the only matching note is soft-deleted" do
      stale_note = user.add_payout_note(content: "Stripe bank sync failed: routing_number_invalid — We couldn't find the bank for that")
      stale_note.mark_deleted!

      get :index, params: { user_id: user.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["payout_note"]).to be_nil
    end

    it "paginates recent payouts with a cursor" do
      newest = create(:payment_completed, user:, created_at: 1.hour.ago)
      middle = create(:payment_completed, user:, created_at: 2.hours.ago)
      oldest = create(:payment_completed, user:, created_at: 3.hours.ago)

      get :index, params: { user_id: user.external_id, limit: 2 }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["recent_payouts"].map { _1["external_id"] }).to eq([newest.external_id, middle.external_id])
      cursor = response.parsed_body["pagination"]["next"]
      expect(cursor).to be_present
      expect(response.parsed_body["pagination"]["limit"]).to eq(2)

      get :index, params: { user_id: user.external_id, limit: 2, cursor: }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["recent_payouts"].map { _1["external_id"] }).to eq([oldest.external_id])
      expect(response.parsed_body["pagination"]).to eq({ "next" => nil, "limit" => 2 })
    end

    it "returns bad request when the cursor is invalid" do
      get :index, params: { user_id: user.external_id, cursor: "invalid" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "invalid cursor" }.as_json)
    end

    it "scopes recent payouts to the requested user" do
      mine = create(:payment_completed, user:, created_at: 1.hour.ago)
      create(:payment_completed, user: create(:user), created_at: 2.hours.ago)

      get :index, params: { user_id: user.external_id }

      expect(response.parsed_body["recent_payouts"].map { _1["external_id"] }).to eq([mine.external_id])
    end

    it "returns a bad request when email and user_id are missing" do
      get :index

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email or user_id is required" }.as_json)
    end

    it "returns not found when the user does not exist" do
      get :index, params: { email: "missing@example.com" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "lists payouts by user_id" do
      get :index, params: { user_id: user.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["user_id"]).to eq(user.external_id)
    end
  end

  describe "POST pause" do
    include_examples "admin api authorization required", :post, :pause

    it "returns 400 when user_id is missing" do
      post :pause

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: user_id_required_message }.as_json)
    end

    it "returns 404 when the user does not exist" do
      post :pause, params: { user_id: "missing" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "pauses payouts and records the admin as the pause source" do
      expect { post :pause, params: { user_id: user.external_id } }.to change { user.reload.payouts_paused_internally? }.from(false).to(true)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "user_id" => user.external_id,
        "message" => "Payouts paused for #{user.external_id}",
        "payouts_paused" => true
      )
      expect(user.reload.payouts_paused_by.to_s).to eq(GUMROAD_ADMIN_ID.to_s)
    end

    it "creates a COMMENT_TYPE_PAYOUTS_PAUSED comment when reason is provided" do
      reason = "Payouts paused due to verification"

      expect { post :pause, params: { user_id: user.external_id, reason: reason } }
        .to change { user.comments.with_type_payouts_paused.count }.by(1)

      comment = user.comments.with_type_payouts_paused.last
      expect(comment.author_id).to eq(GUMROAD_ADMIN_ID)
      expect(comment.content).to eq(reason)
    end

    it "records the legacy token in the audit log" do
      legacy_admin_token = AdminApiToken.find_by!(token_hash: AdminApiToken.hash_token("test-admin-token"))

      expect do
        post :pause, params: { user_id: user.external_id, expected_email: user.email, reason: "Manual review" }
      end.to change { AdminApiAuditLog.count }.by(1)

      audit_log = AdminApiAuditLog.last
      expect(audit_log).to have_attributes(
        action: "payouts.pause",
        target_type: "User",
        target_id: user.id,
        target_external_id: user.external_id,
        actor_user_id: GUMROAD_ADMIN_ID,
        admin_api_token_id: legacy_admin_token.id,
        response_status: 200
      )
      expect(audit_log.params_snapshot).to include(
        "user_id" => user.external_id,
        "expected_email" => "[REDACTED]",
        "reason" => "Manual review"
      )
    end

    it "attributes payout comments and audit rows to a per-actor token" do
      actor = create(:admin_user)
      plaintext_token = AdminApiToken.mint!(actor_user_id: actor.id)
      admin_api_token = AdminApiToken.find_by!(actor_user: actor, token_hash: AdminApiToken.hash_token(plaintext_token))
      request.headers["Authorization"] = "Bearer #{plaintext_token}"

      post :pause, params: { user_id: user.external_id, reason: "Actor review" }

      expect(response).to have_http_status(:ok)
      expect(user.comments.with_type_payouts_paused.last).to have_attributes(
        author_id: actor.id,
        content: "Actor review"
      )
      expect(AdminApiAuditLog.last).to have_attributes(
        action: "payouts.pause",
        actor_user_id: actor.id,
        admin_api_token_id: admin_api_token.id,
        target_id: user.id
      )
    end

    it "does not create a comment when reason is blank" do
      expect { post :pause, params: { user_id: user.external_id, reason: "   " } }
        .not_to change { user.comments.count }

      expect(response).to have_http_status(:ok)
      expect(user.reload.payouts_paused_internally?).to be(true)
    end

    it "short-circuits when payouts are already paused by admin" do
      user.update!(payouts_paused_internally: true, payouts_paused_by: GUMROAD_ADMIN_ID)

      expect { post :pause, params: { user_id: user.external_id, reason: "again" } }
        .not_to change { user.comments.count }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "user_id" => user.external_id,
        "status" => "already_paused",
        "message" => "Payouts are already paused by admin",
        "payouts_paused" => true
      )
    end

    it "asserts admin attribution when payouts were previously paused by the system" do
      user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
      reason = "Manual review pending"

      expect { post :pause, params: { user_id: user.external_id, reason: reason } }
        .to change { user.comments.with_type_payouts_paused.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body).not_to have_key("status")
      expect(user.reload.payouts_paused_by.to_s).to eq(GUMROAD_ADMIN_ID.to_s)
      expect(user.payouts_paused_for_reason).to eq(reason)
    end

    it "asserts admin attribution when payouts were previously paused by Stripe" do
      user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)

      post :pause, params: { user_id: user.external_id, reason: "Stripe escalation" }

      expect(response).to have_http_status(:ok)
      expect(user.reload.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)
    end

    include_examples "requires user_id for payout mutation", :pause
    include_examples "checks expected_email for payout mutation", :pause
  end

  describe "POST resume" do
    include_examples "admin api authorization required", :post, :resume

    it "returns 400 when user_id is missing" do
      post :resume

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: user_id_required_message }.as_json)
    end

    it "returns 404 when the user does not exist" do
      post :resume, params: { user_id: "missing" }

      expect(response).to have_http_status(:not_found)
    end

    it "resumes payouts, clears payouts_paused_by, and records a resume comment" do
      user.update!(payouts_paused_internally: true, payouts_paused_by: GUMROAD_ADMIN_ID)

      expect { post :resume, params: { user_id: user.external_id } }
        .to change { user.reload.payouts_paused_internally? }.from(true).to(false)
        .and change { user.comments.with_type_payouts_resumed.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "user_id" => user.external_id,
        "message" => "Payouts resumed for #{user.external_id}",
        "payouts_paused" => false
      )
      expect(user.reload.payouts_paused_by).to be_nil

      comment = user.comments.with_type_payouts_resumed.last
      expect(comment.author_id).to eq(GUMROAD_ADMIN_ID)
      expect(comment.content).to eq("Payouts resumed.")
    end

    it "reports payouts_paused: true after admin resume when the seller is still self-paused" do
      user.update!(payouts_paused_internally: true, payouts_paused_by: GUMROAD_ADMIN_ID, payouts_paused_by_user: true)

      post :resume, params: { user_id: user.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["payouts_paused"]).to be(true)
      expect(user.reload.payouts_paused_internally?).to be(false)
      expect(user.payouts_paused_by_user?).to be(true)
    end

    it "short-circuits when payouts are not paused by admin" do
      expect { post :resume, params: { user_id: user.external_id } }
        .not_to change { user.comments.count }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "user_id" => user.external_id,
        "status" => "not_paused",
        "message" => "Payouts are not paused by admin",
        "payouts_paused" => false
      )
    end

    it "reports payouts_paused: true on short-circuit when the seller has self-paused" do
      user.update!(payouts_paused_by_user: true)

      post :resume, params: { user_id: user.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "user_id" => user.external_id,
        "status" => "not_paused",
        "payouts_paused" => true
      )
    end

    include_examples "requires user_id for payout mutation", :resume
    include_examples "checks expected_email for payout mutation", :resume
  end

  describe "POST issue" do
    include_examples "admin api authorization required", :post, :issue

    it "returns 400 when user_id is missing" do
      post :issue, params: { payout_processor: "stripe", payout_period_end_date: 1.day.ago.to_date.to_s }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: user_id_required_message }.as_json)
    end

    it "returns 404 when the user does not exist" do
      post :issue, params: { user_id: "missing", payout_processor: "stripe", payout_period_end_date: 1.day.ago.to_date.to_s }

      expect(response).to have_http_status(:not_found)
    end

    it "returns 400 when payout_processor is invalid" do
      post :issue, params: { user_id: user.external_id, payout_processor: "ach", payout_period_end_date: 1.day.ago.to_date.to_s }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq("payout_processor must be stripe or paypal")
    end

    it "returns 400 when payout_period_end_date is missing" do
      post :issue, params: { user_id: user.external_id, payout_processor: "stripe" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq("payout_period_end_date is required")
    end

    it "returns 400 when payout_period_end_date is invalid" do
      post :issue, params: { user_id: user.external_id, payout_processor: "stripe", payout_period_end_date: "not-a-date" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq("payout_period_end_date is invalid")
    end

    it "returns 400 without writing an audit row when payout_period_end_date is today or in the future" do
      [Date.current, Date.current + 1].each do |date|
        expect do
          post :issue, params: { user_id: user.external_id, payout_processor: "stripe", payout_period_end_date: date.to_s }
        end.not_to change { AdminApiAuditLog.count }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["message"]).to eq("payout_period_end_date must be in the past")
      end
    end

    it "issues a stripe payout via Payouts.create_payments_for_balances_up_to_date_for_users" do
      payment = create(:payment_completed, user:)
      date = 1.day.ago.to_date

      expect(Payouts).to receive(:create_payments_for_balances_up_to_date_for_users).with(
        date, PayoutProcessorType::STRIPE, [user], from_admin: true
      ).and_return([[payment]])

      post :issue, params: { user_id: user.external_id, payout_processor: "stripe", payout_period_end_date: date.to_s }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "user_id" => user.external_id,
        "payout" => hash_including("external_id" => payment.external_id, "state" => "completed")
      )
    end

    it "sets should_paypal_payout_be_split when paypal split is requested" do
      payment = create(:payment_completed, user:, processor: PayoutProcessorType::PAYPAL)
      date = 1.day.ago.to_date

      allow(Payouts).to receive(:create_payments_for_balances_up_to_date_for_users).and_return([[payment]])

      expect do
        post :issue, params: { user_id: user.external_id, payout_processor: "paypal", payout_period_end_date: date.to_s, should_split_the_amount: "true" }
      end.to change { user.reload.should_paypal_payout_be_split? }.from(false).to(true)

      expect(response).to have_http_status(:ok)
    end

    it "returns 422 when no payment is created" do
      date = 1.day.ago.to_date
      allow(Payouts).to receive(:create_payments_for_balances_up_to_date_for_users).and_return([])

      post :issue, params: { user_id: user.external_id, payout_processor: "stripe", payout_period_end_date: date.to_s }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include("success" => false, "message" => "Payment was not sent.")
    end

    it "returns 422 when the payment failed" do
      failed_payment = create(:payment_failed, user:)
      failed_payment.errors.add(:base, "Insufficient funds")
      date = 1.day.ago.to_date
      allow(Payouts).to receive(:create_payments_for_balances_up_to_date_for_users).and_return([[failed_payment]])

      post :issue, params: { user_id: user.external_id, payout_processor: "stripe", payout_period_end_date: date.to_s }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to eq("Insufficient funds")
    end

    it "writes an admin audit log" do
      payment = create(:payment_completed, user:)
      date = 1.day.ago.to_date
      allow(Payouts).to receive(:create_payments_for_balances_up_to_date_for_users).and_return([[payment]])

      expect do
        post :issue, params: { user_id: user.external_id, payout_processor: "stripe", payout_period_end_date: date.to_s }
      end.to change { AdminApiAuditLog.count }.by(1)

      expect(AdminApiAuditLog.last).to have_attributes(
        action: "payouts.issue",
        target_type: "User",
        target_id: user.id,
        response_status: 200
      )
    end

    include_examples "requires user_id for payout mutation", :issue, extra_params: { payout_processor: "stripe", payout_period_end_date: 1.day.ago.to_date.to_s }
    include_examples "checks expected_email for payout mutation", :issue, extra_params: { payout_processor: "stripe", payout_period_end_date: 1.day.ago.to_date.to_s }
  end
end
