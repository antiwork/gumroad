# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::PayoutsController do
  let(:user) { create(:compliant_user) }

  before do
    stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)
  end

  describe "POST list" do
    include_examples "admin api authorization required", :post, :list

    it "returns the user's recent payouts and next payout information" do
      payment1 = create(:payment_completed, user:, created_at: 1.day.ago, bank_account: create(:ach_account_stripe_succeed, user:))
      create(:payment_failed, user:, created_at: 2.days.ago)
      create(:payment, user:, created_at: 3.days.ago)
      create(:payment_completed, user:, created_at: 4.days.ago)
      payment5 = create(:payment_completed, user:, created_at: 5.days.ago, processor: PayoutProcessorType::PAYPAL, payment_address: "payme@example.com")
      payment6 = create(:payment_completed, user:, created_at: 6.days.ago)
      payout_note = "Payout paused due to verification"
      user.add_payout_note(content: payout_note)

      allow_any_instance_of(User).to receive(:next_payout_date).and_return(Date.tomorrow)
      allow_any_instance_of(User).to receive(:formatted_balance_for_next_payout_date).and_return("$100.00")

      post :list, params: { email: user.email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["next_payout_date"]).to eq(Date.tomorrow.to_s)
      expect(response.parsed_body["balance_for_next_payout"]).to eq("$100.00")
      expect(response.parsed_body["payout_note"]).to eq(payout_note)

      payouts = response.parsed_body["last_payouts"]
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
      expect(payouts.map { _1["external_id"] }).not_to include(payment6.external_id)
    end

    it "returns a bad request when email is missing" do
      post :list

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email is required" }.as_json)
    end

    it "returns not found when the user does not exist" do
      post :list, params: { email: "missing@example.com" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end
  end

  describe "POST pause" do
    include_examples "admin api authorization required", :post, :pause

    it "returns 400 when email is missing" do
      post :pause

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email is required" }.as_json)
    end

    it "returns 404 when the user does not exist" do
      post :pause, params: { email: "missing@example.com" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "pauses payouts and records the admin as the pause source" do
      expect { post :pause, params: { email: user.email } }.to change { user.reload.payouts_paused_internally? }.from(false).to(true)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "message" => "Payouts paused for #{user.email}",
        "payouts_paused" => true
      )
      expect(user.reload.payouts_paused_by.to_s).to eq(GUMROAD_ADMIN_ID.to_s)
    end

    it "creates a COMMENT_TYPE_PAYOUTS_PAUSED comment when reason is provided" do
      reason = "Payouts paused due to verification"

      expect { post :pause, params: { email: user.email, reason: reason } }
        .to change { user.comments.with_type_payouts_paused.count }.by(1)

      comment = user.comments.with_type_payouts_paused.last
      expect(comment.author_id).to eq(GUMROAD_ADMIN_ID)
      expect(comment.content).to eq(reason)
    end

    it "records the legacy token in the audit log" do
      legacy_admin_token = AdminApiToken.find_by!(token_hash: AdminApiToken.hash_token("test-admin-token"))

      expect do
        post :pause, params: { email: user.email, reason: "Manual review" }
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
        "email" => "[REDACTED]",
        "reason" => "Manual review"
      )
    end

    it "attributes payout comments and audit rows to a per-actor token" do
      actor = create(:admin_user)
      plaintext_token = AdminApiToken.mint!(actor_user_id: actor.id)
      admin_api_token = AdminApiToken.find_by!(actor_user: actor, token_hash: AdminApiToken.hash_token(plaintext_token))
      request.headers["Authorization"] = "Bearer #{plaintext_token}"

      post :pause, params: { email: user.email, reason: "Actor review" }

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
      expect { post :pause, params: { email: user.email, reason: "   " } }
        .not_to change { user.comments.count }

      expect(response).to have_http_status(:ok)
      expect(user.reload.payouts_paused_internally?).to be(true)
    end

    it "short-circuits when payouts are already paused by admin" do
      user.update!(payouts_paused_internally: true, payouts_paused_by: GUMROAD_ADMIN_ID)

      expect { post :pause, params: { email: user.email, reason: "again" } }
        .not_to change { user.comments.count }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "status" => "already_paused",
        "message" => "Payouts are already paused by admin",
        "payouts_paused" => true
      )
    end

    it "asserts admin attribution when payouts were previously paused by the system" do
      user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
      reason = "Manual review pending"

      expect { post :pause, params: { email: user.email, reason: reason } }
        .to change { user.comments.with_type_payouts_paused.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body).not_to have_key("status")
      expect(user.reload.payouts_paused_by.to_s).to eq(GUMROAD_ADMIN_ID.to_s)
      expect(user.payouts_paused_for_reason).to eq(reason)
    end

    it "asserts admin attribution when payouts were previously paused by Stripe" do
      user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)

      post :pause, params: { email: user.email, reason: "Stripe escalation" }

      expect(response).to have_http_status(:ok)
      expect(user.reload.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)
    end
  end

  describe "POST resume" do
    include_examples "admin api authorization required", :post, :resume

    it "returns 400 when email is missing" do
      post :resume

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email is required" }.as_json)
    end

    it "returns 404 when the user does not exist" do
      post :resume, params: { email: "missing@example.com" }

      expect(response).to have_http_status(:not_found)
    end

    it "resumes payouts, clears payouts_paused_by, and records a resume comment" do
      user.update!(payouts_paused_internally: true, payouts_paused_by: GUMROAD_ADMIN_ID)

      expect { post :resume, params: { email: user.email } }
        .to change { user.reload.payouts_paused_internally? }.from(true).to(false)
        .and change { user.comments.with_type_payouts_resumed.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "message" => "Payouts resumed for #{user.email}",
        "payouts_paused" => false
      )
      expect(user.reload.payouts_paused_by).to be_nil

      comment = user.comments.with_type_payouts_resumed.last
      expect(comment.author_id).to eq(GUMROAD_ADMIN_ID)
      expect(comment.content).to eq("Payouts resumed.")
    end

    it "reports payouts_paused: true after admin resume when the seller is still self-paused" do
      user.update!(payouts_paused_internally: true, payouts_paused_by: GUMROAD_ADMIN_ID, payouts_paused_by_user: true)

      post :resume, params: { email: user.email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["payouts_paused"]).to be(true)
      expect(user.reload.payouts_paused_internally?).to be(false)
      expect(user.payouts_paused_by_user?).to be(true)
    end

    it "short-circuits when payouts are not paused by admin" do
      expect { post :resume, params: { email: user.email } }
        .not_to change { user.comments.count }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "status" => "not_paused",
        "message" => "Payouts are not paused by admin",
        "payouts_paused" => false
      )
    end

    it "reports payouts_paused: true on short-circuit when the seller has self-paused" do
      user.update!(payouts_paused_by_user: true)

      post :resume, params: { email: user.email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "status" => "not_paused",
        "payouts_paused" => true
      )
    end
  end

  describe "POST issue" do
    include_examples "admin api authorization required", :post, :issue

    it "returns 400 when email is missing" do
      post :issue, params: { payout_processor: "stripe", payout_period_end_date: 1.day.ago.to_date.to_s }

      expect(response).to have_http_status(:bad_request)
    end

    it "returns 404 when the user does not exist" do
      post :issue, params: { email: "missing@example.com", payout_processor: "stripe", payout_period_end_date: 1.day.ago.to_date.to_s }

      expect(response).to have_http_status(:not_found)
    end

    it "returns 400 when payout_processor is invalid" do
      post :issue, params: { email: user.email, payout_processor: "ach", payout_period_end_date: 1.day.ago.to_date.to_s }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq("payout_processor must be stripe or paypal")
    end

    it "returns 400 when payout_period_end_date is missing" do
      post :issue, params: { email: user.email, payout_processor: "stripe" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq("payout_period_end_date is required")
    end

    it "returns 400 when payout_period_end_date is invalid" do
      post :issue, params: { email: user.email, payout_processor: "stripe", payout_period_end_date: "not-a-date" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq("payout_period_end_date is invalid")
    end

    it "returns 400 without writing an audit row when payout_period_end_date is today or in the future" do
      [Date.current, Date.current + 1].each do |date|
        expect do
          post :issue, params: { email: user.email, payout_processor: "stripe", payout_period_end_date: date.to_s }
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

      post :issue, params: { email: user.email, payout_processor: "stripe", payout_period_end_date: date.to_s }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "payout" => hash_including("external_id" => payment.external_id, "state" => "completed")
      )
    end

    it "sets should_paypal_payout_be_split when paypal split is requested" do
      payment = create(:payment_completed, user:, processor: PayoutProcessorType::PAYPAL)
      date = 1.day.ago.to_date

      allow(Payouts).to receive(:create_payments_for_balances_up_to_date_for_users).and_return([[payment]])

      expect do
        post :issue, params: { email: user.email, payout_processor: "paypal", payout_period_end_date: date.to_s, should_split_the_amount: "true" }
      end.to change { user.reload.should_paypal_payout_be_split? }.from(false).to(true)

      expect(response).to have_http_status(:ok)
    end

    it "returns 422 when no payment is created" do
      date = 1.day.ago.to_date
      allow(Payouts).to receive(:create_payments_for_balances_up_to_date_for_users).and_return([])

      post :issue, params: { email: user.email, payout_processor: "stripe", payout_period_end_date: date.to_s }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include("success" => false, "message" => "Payment was not sent.")
    end

    it "returns 422 when the payment failed" do
      failed_payment = create(:payment_failed, user:)
      failed_payment.errors.add(:base, "Insufficient funds")
      date = 1.day.ago.to_date
      allow(Payouts).to receive(:create_payments_for_balances_up_to_date_for_users).and_return([[failed_payment]])

      post :issue, params: { email: user.email, payout_processor: "stripe", payout_period_end_date: date.to_s }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to eq("Insufficient funds")
    end

    it "writes an admin audit log" do
      payment = create(:payment_completed, user:)
      date = 1.day.ago.to_date
      allow(Payouts).to receive(:create_payments_for_balances_up_to_date_for_users).and_return([[payment]])

      expect do
        post :issue, params: { email: user.email, payout_processor: "stripe", payout_period_end_date: date.to_s }
      end.to change { AdminApiAuditLog.count }.by(1)

      expect(AdminApiAuditLog.last).to have_attributes(
        action: "payouts.issue",
        target_type: "User",
        target_id: user.id,
        response_status: 200
      )
    end
  end

  describe "POST scheduled_list" do
    include_examples "admin api authorization required", :post, :scheduled_list

    it "returns scheduled payouts ordered by id desc" do
      first = create(:scheduled_payout, user:)
      second = create(:scheduled_payout, user: create(:user))

      post :scheduled_list

      expect(response).to have_http_status(:ok)
      payload = response.parsed_body
      expect(payload["success"]).to be(true)
      expect(payload["scheduled_payouts"].map { _1["external_id"] }).to eq([second.external_id, first.external_id])
    end

    it "filters by status when provided" do
      flagged = create(:scheduled_payout, user:, status: "flagged")
      create(:scheduled_payout, user: create(:user), status: "pending")

      post :scheduled_list, params: { status: "flagged" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["scheduled_payouts"].map { _1["external_id"] }).to eq([flagged.external_id])
    end

    it "returns 400 when status is invalid" do
      post :scheduled_list, params: { status: "bogus" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "status is invalid" }.as_json)
    end

    it "caps the limit at SCHEDULED_PAYOUTS_MAX_LIMIT" do
      post :scheduled_list, params: { limit: 9999 }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["limit"]).to eq(50)
    end

    it "uses the default limit when limit is missing or non-positive" do
      post :scheduled_list

      expect(response.parsed_body["limit"]).to eq(20)

      post :scheduled_list, params: { limit: 0 }

      expect(response.parsed_body["limit"]).to eq(20)
    end
  end

  describe "POST scheduled_execute" do
    include_examples "admin api authorization required", :post, :scheduled_execute, { id: "abc" }

    it "returns 404 when the scheduled payout is not found" do
      post :scheduled_execute, params: { id: "missing" }

      expect(response).to have_http_status(:not_found)
    end

    it "executes a pending scheduled payout" do
      scheduled_payout = create(:scheduled_payout, user:)
      allow_any_instance_of(ScheduledPayout).to receive(:execute!).and_return(:executed)

      post :scheduled_execute, params: { id: scheduled_payout.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("success" => true, "result" => "executed")
    end

    it "promotes a flagged scheduled payout to pending before executing" do
      scheduled_payout = create(:scheduled_payout, user:, status: "flagged")
      allow_any_instance_of(ScheduledPayout).to receive(:execute!).and_return(:executed)

      expect do
        post :scheduled_execute, params: { id: scheduled_payout.external_id }
      end.to change { scheduled_payout.reload.status }.from("flagged").to("pending")

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["result"]).to eq("executed")
    end

    it "returns 422 when the scheduled payout is already executed" do
      scheduled_payout = create(:scheduled_payout, user:, status: "executed")

      post :scheduled_execute, params: { id: scheduled_payout.external_id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to eq("Cannot execute a executed scheduled payout.")
    end

    it "returns 422 and the error message when execute! raises" do
      scheduled_payout = create(:scheduled_payout, user:)
      allow_any_instance_of(ScheduledPayout).to receive(:execute!).and_raise("nope")

      post :scheduled_execute, params: { id: scheduled_payout.external_id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include("success" => false, "message" => "nope")
    end

    it "writes an admin audit log targeting the scheduled payout" do
      scheduled_payout = create(:scheduled_payout, user:)
      allow_any_instance_of(ScheduledPayout).to receive(:execute!).and_return(:executed)

      expect do
        post :scheduled_execute, params: { id: scheduled_payout.external_id }
      end.to change { AdminApiAuditLog.count }.by(1)

      expect(AdminApiAuditLog.last).to have_attributes(
        action: "payouts.scheduled_execute",
        target_type: "ScheduledPayout",
        target_id: scheduled_payout.id,
        target_external_id: scheduled_payout.external_id,
        response_status: 200
      )
    end
  end

  describe "POST scheduled_cancel" do
    include_examples "admin api authorization required", :post, :scheduled_cancel, { id: "abc" }

    it "returns 404 when the scheduled payout is not found" do
      post :scheduled_cancel, params: { id: "missing" }

      expect(response).to have_http_status(:not_found)
    end

    it "cancels a pending scheduled payout" do
      scheduled_payout = create(:scheduled_payout, user:)

      expect do
        post :scheduled_cancel, params: { id: scheduled_payout.external_id }
      end.to change { scheduled_payout.reload.status }.from("pending").to("cancelled")

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
    end

    it "returns 422 and the error message when cancel! raises" do
      scheduled_payout = create(:scheduled_payout, user:)
      allow_any_instance_of(ScheduledPayout).to receive(:cancel!).and_raise("already executed")

      post :scheduled_cancel, params: { id: scheduled_payout.external_id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include("success" => false, "message" => "already executed")
    end

    it "writes an admin audit log targeting the scheduled payout" do
      scheduled_payout = create(:scheduled_payout, user:)

      expect do
        post :scheduled_cancel, params: { id: scheduled_payout.external_id }
      end.to change { AdminApiAuditLog.count }.by(1)

      expect(AdminApiAuditLog.last).to have_attributes(
        action: "payouts.scheduled_cancel",
        target_type: "ScheduledPayout",
        target_id: scheduled_payout.id,
        response_status: 200
      )
    end
  end
end
