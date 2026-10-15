# frozen_string_literal: true

require "spec_helper"

describe "Stripe restraint notices admin API", type: :request do
  let(:admin_user) { create(:admin_user) }
  let(:seller) { create(:user, email: "seller@example.com") }
  let(:headers) { { "Authorization" => "Bearer #{AdminApiToken.mint!(actor_user_id: admin_user.id)}" } }
  let(:notice_params) do
    { stripe_account_id: "acct_1TestCourtOrder05", firm_name: "Example Legal LLP", firm_email: "notices@example.com", notice_key: "test-court-order-notice-0005" }
  end

  before do
    create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_1TestCourtOrder05")
    headers
    host! VALID_API_REQUEST_HOSTS.first
  end

  def sql_writes(&block)
    writes = []
    callback = ->(*, payload) { writes << payload[:sql] unless payload[:sql].match?(/\A\s*(SELECT|SHOW|SET|SAVEPOINT|RELEASE SAVEPOINT|ROLLBACK TO SAVEPOINT|BEGIN|COMMIT)\b/i) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    writes
  end

  it "answers a dry run without any database write, queued job or email" do
    writes = sql_writes { post "/internal/admin/stripe_restraint_notices", params: notice_params, headers:, as: :json }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("status" => "dry_run", "already_sent" => false)
    expect(writes).to eq([])
    expect(StripeRestraintNoticeEmailJob.jobs.size).to eq(0)
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it "queues until the mail service accepts, sends once, then answers already_sent without queueing" do
    path = "/internal/admin/stripe_restraint_notices"
    post path, params: notice_params.merge(dry_run: false), headers:, as: :json
    expect(response.parsed_body).to include("status" => "queued", "delivery_status" => "pending")
    post path, params: notice_params.merge(dry_run: false), headers:, as: :json
    expect(response.parsed_body).to include("status" => "queued", "delivery_status" => "pending")

    writes = sql_writes { post path, params: notice_params, headers:, as: :json }
    expect(response.parsed_body).to include("status" => "dry_run", "delivery_status" => "pending")
    expect(writes).to eq([])

    StripeRestraintNoticeEmailJob.drain
    post path, params: notice_params.merge(dry_run: false), headers:, as: :json

    expect(response.parsed_body).to include("status" => "already_sent", "already_sent" => true, "delivery_status" => "accepted")
    expect(StripeRestraintNoticeEmailJob.jobs.size).to eq(0)
    expect(ActionMailer::Base.deliveries.map(&:to)).to eq([["seller@example.com"]])
  end
end
