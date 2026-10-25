# frozen_string_literal: true

require "spec_helper"

describe "Low-balance probation recoveries admin API", type: :request, versioning: true do
  let(:admin_user) { create(:admin_user) }
  let(:headers) { { "Authorization" => "Bearer #{AdminApiToken.mint!(actor_user_id: admin_user.id)}" } }
  let(:seller) { create(:user) }
  let!(:merchant_account) do
    create(:merchant_account, user: seller, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                              charge_processor_merchant_id: "acct_lowbalancerecovery")
  end

  before do
    seller.mark_compliant!(author_name: "admin")
    LiftPlatformStripePauseJob.jobs.clear
    seller.send(:disable_refunds_and_put_on_probation!)
    create(:balance, user: seller, amount_cents: 100_00)
    headers
    host! VALID_API_REQUEST_HOSTS.first
  end

  def written_tables(&block)
    tables = []
    callback = lambda do |*, payload|
      sql = payload[:sql]
      next if sql.match?(/\A\s*(SELECT|SHOW|SET|SAVEPOINT|RELEASE SAVEPOINT|ROLLBACK TO SAVEPOINT|BEGIN|COMMIT)\b/i)

      tables << sql[/\A\s*(?:INSERT INTO|UPDATE|DELETE FROM)\s+`?(\w+)`?/i, 1]
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    tables
  end

  def stripe_account(charges_paused:)
    Stripe::StripeObject.construct_from(
      id: "acct_lowbalancerecovery",
      risk_controls: { charges: { pause_requested: charges_paused }, payouts: { pause_requested: false } },
      requirements: { disabled_reason: charges_paused ? "platform_paused" : nil, past_due: [] },
      future_requirements: { past_due: [] },
      capabilities: { transfers: "active" }
    )
  end

  it "previews without writing account data, then executes and hands the Stripe lift to its job" do
    tables = written_tables do
      post "/internal/admin/low_balance_probation_recoveries/preview", params: { user_ids: [seller.external_id] }, headers:, as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(tables.uniq.sort).to eq(%w[admin_api_audit_logs admin_api_tokens])
    expect(seller.reload).to be_on_probation
    snapshot = response.parsed_body["snapshot"]

    post "/internal/admin/low_balance_probation_recoveries/execute", params: { user_ids: [seller.external_id], snapshot: }, headers:, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["results"].sole).to include("outcome" => "recovered", "target_state" => "compliant")
    expect(seller.reload).to be_compliant
    expect(LiftPlatformStripePauseJob.jobs.map { _1["args"] }).to eq([[seller.id]])

    allow(Stripe::Account).to receive(:retrieve).with("acct_lowbalancerecovery").and_return(stripe_account(charges_paused: true))
    allow(Stripe::Account).to receive(:update).and_return(stripe_account(charges_paused: false))
    LiftPlatformStripePauseJob.drain

    expect(Stripe::Account).to have_received(:update).with("acct_lowbalancerecovery", risk_controls: { charges: { pause_requested: false } })
  end

  it "rejects a request without a per-actor admin token" do
    post "/internal/admin/low_balance_probation_recoveries/execute", params: { user_ids: [seller.external_id], snapshot: "x" }, as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(seller.reload).to be_on_probation
  end
end
