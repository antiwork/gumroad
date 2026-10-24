# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::LowBalanceProbationRecoveriesController, versioning: true do
  let(:admin_user) { create(:admin_user) }
  let(:per_actor_token) { AdminApiToken.mint!(actor_user_id: admin_user.id) }

  def probated_seller(prior: :not_reviewed, balance_cents: 100_00)
    create(:user).tap do |seller|
      seller.mark_compliant!(author_name: "admin") if prior == :compliant
      seller.send(:disable_refunds_and_put_on_probation!)
      create(:balance, user: seller, amount_cents: balance_cents)
    end
  end

  def authenticate!
    request.headers["Authorization"] = "Bearer #{per_actor_token}"
  end

  def preview(user_ids)
    post :preview, params: { user_ids: }, as: :json
    response.parsed_body
  end

  def execute(user_ids, snapshot)
    post :execute, params: { user_ids:, snapshot: }, as: :json
    response.parsed_body
  end

  it "inherits from Api::Internal::Admin::BaseController" do
    expect(described_class.superclass).to eq(Api::Internal::Admin::BaseController)
  end

  %i[preview execute].each do |action|
    describe "POST #{action} authorization" do
      include_examples "admin api authorization required", :post, action, { user_ids: ["x"] }

      it "rejects the legacy shared admin token" do
        seller = probated_seller

        expect { post action, params: { user_ids: [seller.external_id] }, as: :json }.not_to change { AdminApiAuditLog.count }

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body["message"]).to eq("per-actor admin token is required")
        expect(seller.reload).to be_on_probation
      end
    end
  end

  describe "POST preview" do
    before { authenticate! }

    it "reports each requested account and signs only the eligible ones, without changing them" do
      eligible = probated_seller(prior: :compliant)
      short = probated_seller(balance_cents: 50_00)

      body = nil
      expect { body = preview([eligible.external_id, short.external_id, "missing-id"]) }
        .to change { AdminApiAuditLog.count }.by(1)
        .and not_change { eligible.reload.user_risk_state }

      expect(response).to have_http_status(:ok)
      expect(body["eligible_user_ids"]).to eq([eligible.external_id])
      expect(body["snapshot"]).to be_present
      expect(Time.zone.parse(body["snapshot_expires_at"])).to be_within(5.seconds).of(1.hour.from_now)
      expect(body["rules_digest"]).to eq(LowBalanceProbationRecovery::RULES_DIGEST)
      accounts = body["accounts"].index_by { _1["user_id"] }
      expect(accounts[eligible.external_id]).to include("eligible" => true, "reason" => nil, "prior_state" => "compliant",
                                                        "target_state" => "compliant", "provenance" => "comment_version",
                                                        "unpaid_balance_cents" => 100_00)
      expect(accounts[eligible.external_id]["probation_comment_id"]).to be_present
      expect(accounts[eligible.external_id]["transition_version_id"]).to be_present
      expect(accounts[short.external_id]).to include("eligible" => false, "reason" => "insufficient_balance")
      expect(accounts["missing-id"]).to eq("user_id" => "missing-id", "eligible" => false, "reason" => "user_not_found")

      audit_log = AdminApiAuditLog.last
      expect(audit_log.action).to eq("low_balance_probation_recoveries.preview")
      expect(audit_log.actor_user_id).to eq(admin_user.id)
      expect(audit_log.target_id).to be_nil
      expect(audit_log.request_id).to eq(body["request_id"])
      expect(audit_log.params_snapshot["user_ids"]).to eq([eligible.external_id, short.external_id, "missing-id"])
      expect(audit_log.response_status).to eq(200)
    end

    it "returns no snapshot when nothing is eligible" do
      body = preview([probated_seller(balance_cents: 0).external_id])

      expect(body["snapshot"]).to be_nil
      expect(body["eligible_user_ids"]).to eq([])
    end

    it "requires an explicit, bounded and distinct list" do
      seller = probated_seller

      preview([])
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq("user_ids is required")

      preview([seller.external_id, seller.external_id])
      expect(response.parsed_body["message"]).to eq("user_ids must not repeat")

      preview(Array.new(described_class::MAX_ACCOUNTS + 1) { "id-#{_1}" })
      expect(response.parsed_body["message"]).to eq("at most #{described_class::MAX_ACCOUNTS} user_ids per request")

      expect(AdminApiAuditLog.where(action: "low_balance_probation_recoveries.preview").pluck(:response_status)).to eq([400, 400, 400])
    end
  end

  describe "POST execute" do
    before { authenticate! }

    it "recovers the reviewed accounts and reads each committed result back" do
      compliant = probated_seller(prior: :compliant)
      not_reviewed = probated_seller
      snapshot = preview([compliant.external_id, not_reviewed.external_id])["snapshot"]

      body = nil
      expect { body = execute([compliant.external_id, not_reviewed.external_id], snapshot) }
        .to change { LiftPlatformStripePauseJob.jobs.size }.by(1)
        .and change { AdminApiAuditLog.count }.by(3)
        .and not_change { UpdateSellerRefundEligibilityJob.jobs.size }

      expect(response).to have_http_status(:ok)
      expect(body["counts"]).to eq("recovered" => 2)
      results = body["results"].index_by { _1["user_id"] }
      expect(results[compliant.external_id]).to include("outcome" => "recovered", "target_state" => "compliant")
      expect(results[compliant.external_id]["readback"]).to include("user_risk_state" => "compliant", "refunds_disabled" => false,
                                                                    "recovery_comment_author_id" => admin_user.id)
      expect(results[not_reviewed.external_id]["readback"]).to include("user_risk_state" => "not_reviewed", "refunds_disabled" => true)
      expect(compliant.reload).to be_compliant
      expect(not_reviewed.reload).to be_not_reviewed

      request_log = AdminApiAuditLog.find_by!(action: "low_balance_probation_recoveries.execute")
      expect(request_log.actor_user_id).to eq(admin_user.id)
      expect(request_log.request_id).to eq(body["request_id"])
      expect(request_log.params_snapshot["user_ids"]).to eq([compliant.external_id, not_reviewed.external_id])
      expect(request_log.params_snapshot["snapshot"]).to eq("[REDACTED]")
      account_logs = AdminApiAuditLog.where(action: "low_balance_probation_recoveries.execute_account").order(:id)
      logged = account_logs.map { [_1.target_type, _1.target_id, _1.request_id, _1.params_snapshot["outcome"]] }
      expect(logged).to eq([["User", compliant.id, body["request_id"], "recovered"], ["User", not_reviewed.id, body["request_id"], "recovered"]])
      expect(account_logs.first.params_snapshot).to include("snapshot_request_id" => body["snapshot_request_id"], "target_state" => "compliant")
      expect(account_logs.first.params_snapshot["readback"]).to include("user_risk_state" => "compliant", "refunds_disabled" => false)
      recovery_comment = compliant.comments.find_by!(idempotency_key: "low_balance_probation_recovery:#{compliant.comments.where(author_name: "LowBalanceFraudCheck", comment_type: "on").last.id}")
      expect(recovery_comment.content).to include("admin API request #{body["request_id"]}")
    end

    it "answers a repeat of the same snapshot with already_recovered" do
      seller = probated_seller
      snapshot = preview([seller.external_id])["snapshot"]
      execute([seller.external_id], snapshot)

      body = nil
      expect { body = execute([seller.external_id], snapshot) }.not_to change { seller.comments.count }

      expect(body["results"].sole).to include("outcome" => "already_recovered", "recovered_by" => "admin")
    end

    it "does not act on an account the automatic check recovered after the review" do
      seller = probated_seller
      snapshot = preview([seller.external_id])["snapshot"]
      LowBalanceProbationRecovery.new(seller.reload).recover_automatically!

      body = execute([seller.external_id], snapshot)

      expect(body["results"].sole).to include("outcome" => "already_recovered", "recovered_by" => "automatic")
    end

    it "marks an account stale when its probation changed after the review" do
      seller = probated_seller
      snapshot = preview([seller.external_id])["snapshot"]
      seller.mark_compliant!(author_name: "admin")
      travel 1.minute
      seller.send(:disable_refunds_and_put_on_probation!)

      body = execute([seller.external_id], snapshot)

      expect(body["results"].sole).to include("outcome" => "stale_snapshot", "reason" => "facts_changed_since_review")
      expect(seller.reload).to be_on_probation
    end

    it "skips an account a newer decision now covers" do
      seller = probated_seller
      snapshot = preview([seller.external_id])["snapshot"]
      seller.suspend_for_fraud!(author_name: "admin")

      body = execute([seller.external_id], snapshot)

      expect(body["results"].sole).to include("outcome" => "skipped", "reason" => "suspended")
      expect(seller.reload).to be_suspended_for_fraud
    end

    it "stops at the first error and leaves later accounts untouched" do
      first = probated_seller
      second = probated_seller
      snapshot = preview([first.external_id, second.external_id])["snapshot"]
      allow_any_instance_of(User).to receive(:add_user_comment).and_raise(ActiveRecord::RecordInvalid)

      body = execute([first.external_id, second.external_id], snapshot)

      expect(body["results"].first).to include("user_id" => first.external_id, "outcome" => "error", "reason" => "rolled_back",
                                               "rolled_back" => true, "error_class" => "ActiveRecord::RecordInvalid")
      expect(body["results"].second).to eq("user_id" => second.external_id, "outcome" => "not_attempted")
      expect(first.reload).to be_on_probation
      expect(second.reload).to be_on_probation
      expect(AdminApiAuditLog.where(action: "low_balance_probation_recoveries.execute_account").order(:id)
                             .map { [_1.target_id, _1.params_snapshot["outcome"], _1.error_class] })
        .to eq([[first.id, "error", "ActiveRecord::RecordInvalid"], [second.id, "not_attempted", nil]])
    end

    it "reports a recovery that committed before its Stripe-lift enqueue failed, and stops" do
      first = probated_seller(prior: :compliant)
      second = probated_seller
      snapshot = preview([first.external_id, second.external_id])["snapshot"]
      allow(LiftPlatformStripePauseJob).to receive(:perform_async).and_raise(Redis::CannotConnectError)

      body = execute([first.external_id, second.external_id], snapshot)

      expect(body["results"].first).to include("outcome" => "committed_unconfirmed", "reason" => "post_commit_step_failed",
                                               "rolled_back" => false, "error_class" => "Redis::CannotConnectError")
      expect(body["results"].first["readback"]).to include("user_risk_state" => "compliant", "refunds_disabled" => false,
                                                           "recovery_comment_author_id" => admin_user.id)
      expect(body["results"].second).to eq("user_id" => second.external_id, "outcome" => "not_attempted")
      first.reload
      expect(first).to be_compliant
      expect(first.refunds_disabled?).to be(false)
      expect(second.reload).to be_on_probation
      expect(LiftPlatformStripePauseJob).to have_received(:perform_async).with(first.id).once
    end

    it "refuses a snapshot another admin reviewed, before touching any account" do
      seller = probated_seller
      snapshot = preview([seller.external_id])["snapshot"]
      other_admin = create(:admin_user)
      request.headers["Authorization"] = "Bearer #{AdminApiToken.mint!(actor_user_id: other_admin.id)}"

      body = nil
      expect { body = execute([seller.external_id], snapshot) }
        .to change { AdminApiAuditLog.where(action: "low_balance_probation_recoveries.execute", actor_user_id: other_admin.id, response_status: 422).count }.by(1)
        .and not_change { AdminApiAuditLog.where(action: "low_balance_probation_recoveries.execute_account").count }
        .and not_change { seller.reload.comments.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(body["message"]).to eq("snapshot was reviewed by a different admin")
      expect(seller.reload).to be_on_probation
    end

    it "marks an account stale when the check re-asserted its probation after the review" do
      seller = probated_seller
      snapshot = preview([seller.external_id])["snapshot"]
      travel 1.minute
      seller.reload.send(:disable_refunds_and_put_on_probation!)

      body = execute([seller.external_id], snapshot)

      expect(body["results"].sole).to include("outcome" => "stale_snapshot", "reason" => "facts_changed_since_review")
      expect(seller.reload).to be_on_probation
      expect(AdminApiAuditLog.find_by!(action: "low_balance_probation_recoveries.execute_account", target_id: seller.id)
                             .params_snapshot).to include("outcome" => "stale_snapshot")
    end

    it "refuses ids outside the reviewed snapshot before touching any account" do
      reviewed = probated_seller
      unreviewed = probated_seller
      snapshot = preview([reviewed.external_id])["snapshot"]

      body = execute([reviewed.external_id, unreviewed.external_id], snapshot)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(body["message"]).to eq("user_ids are not eligible in the reviewed snapshot: #{unreviewed.external_id}")
      expect(reviewed.reload).to be_on_probation
    end

    it "refuses a missing, forged, expired or differently-ruled snapshot, and audits the refusal" do
      seller = probated_seller
      snapshot = preview([seller.external_id])["snapshot"]
      verifier = Rails.application.message_verifier(LowBalanceProbationRecovery::Snapshot::PURPOSE)
      facts = LowBalanceProbationRecovery.new(seller.reload).evaluate.snapshot_facts
      other_rules = verifier.generate({ "format" => 1, "rules_digest" => "0" * 64, "accounts" => [facts] },
                                      purpose: LowBalanceProbationRecovery::Snapshot::PURPOSE, expires_in: 1.hour)

      [
        [nil, "snapshot is required"],
        ["#{snapshot}x", "snapshot is invalid or expired"],
        [other_rules, "snapshot was reviewed under different recovery rules"],
      ].each do |candidate, message|
        execute([seller.external_id], candidate)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["message"]).to eq(message)
      end

      travel LowBalanceProbationRecovery::Snapshot::TTL + 1.minute
      execute([seller.external_id], snapshot)
      expect(response.parsed_body["message"]).to eq("snapshot is invalid or expired")

      expect(seller.reload).to be_on_probation
      expect(AdminApiAuditLog.where(action: "low_balance_probation_recoveries.execute").pluck(:response_status)).to eq([422, 422, 422, 422])
    end
  end
end
