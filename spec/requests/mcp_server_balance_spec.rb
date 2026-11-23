# frozen_string_literal: true

require "spec_helper"

describe "MCP get_balance" do
  around { |example| travel_to(Time.utc(2026, 12, 2, 12)) { example.run } }

  before do
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")

    @seller = create(:user, payment_address: "seller@example.com")
    @app = create(:oauth_application, owner: create(:user))
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_payouts")
  end

  def get_balance(token: @token)
    post "/muse/v1/mcp",
         params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "get_balance", arguments: {} } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN, "ACCEPT" => "application/json, text/event-stream", "Authorization" => "Bearer #{token.token}" }
  end

  def result = response.parsed_body.dig("result", "structuredContent")

  it "returns the unpaid balance and the estimated next payout" do
    create(:balance, user: @seller, amount_cents: 11_113, date: Date.new(2026, 11, 20))

    get_balance

    expect(result).to eq(
      "currency" => "usd",
      "unpaid_balance_cents" => 11_113,
      "payouts_status" => "payable",
      "minimum_payout_cents" => @seller.minimum_payout_amount_cents,
      "next_payout" => {
        "estimated_date" => @seller.next_payout_date.iso8601,
        "estimated_amount_cents" => 11_113
      },
      "note" => "Estimates only; a payout is not guaranteed."
    )
    expect(Date.parse(result.dig("next_payout", "estimated_date"))).to be > Date.new(2026, 12, 1)
  end

  it "leaves out balance that falls after the payout cycle's cut-off" do
    create(:balance, user: @seller, amount_cents: 11_113, date: Date.new(2026, 11, 20))
    create(:balance, user: @seller, amount_cents: 5_000, date: Date.new(2026, 12, 1))

    get_balance

    expect(result["unpaid_balance_cents"]).to eq(16_113)
    expect(result.dig("next_payout", "estimated_amount_cents")).to eq(11_113)
  end

  it "ignores paid balances and other sellers' balances" do
    create(:balance, user: @seller, amount_cents: 20_000, date: Date.new(2026, 11, 13), state: "paid")
    create(:balance, user: create(:user), amount_cents: 90_000, date: Date.new(2026, 11, 20))

    get_balance

    expect(result["unpaid_balance_cents"]).to eq(0)
    expect(result["next_payout"]).to be_nil
  end

  it "gives no estimate when the balance is below the minimum" do
    create(:balance, user: @seller, amount_cents: @seller.minimum_payout_amount_cents - 1, date: Date.new(2026, 11, 20))

    get_balance

    expect(result).to include("unpaid_balance_cents" => @seller.minimum_payout_amount_cents - 1, "next_payout_unavailable_reason" => "below_minimum_balance")
    expect(result).not_to have_key("next_payout")
  end

  it "uses the seller's own payout threshold as the minimum" do
    @seller.update!(payout_threshold_cents: 50_000)
    create(:balance, user: @seller, amount_cents: 11_113, date: Date.new(2026, 11, 20))

    get_balance

    expect(result).to include("minimum_payout_cents" => 50_000, "next_payout_unavailable_reason" => "below_minimum_balance")
  end

  it "shows a payout hold and withholds the estimate" do
    create(:balance, user: @seller, amount_cents: 11_113, date: Date.new(2026, 11, 20))
    @seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_ADMIN)

    get_balance

    expect(result).to include(
      "unpaid_balance_cents" => 11_113,
      "payouts_status" => "paused",
      "payouts_paused_by" => "admin",
      "next_payout_unavailable_reason" => "payouts_paused"
    )
    expect(result).not_to have_key("next_payout")
  end

  it "reports a seller-paused account as paused by the seller" do
    create(:balance, user: @seller, amount_cents: 11_113, date: Date.new(2026, 11, 20))
    @seller.update!(payouts_paused_by_user: true)

    get_balance

    expect(result).to include("payouts_status" => "paused", "payouts_paused_by" => "user")
  end

  it "requires the payouts scope" do
    token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_sales")

    get_balance(token:)

    expect(response.parsed_body.dig("error", "message")).to eq("This tool requires the view_payouts or account scope.")
  end

  it "does not change any balance or payout" do
    create(:balance, user: @seller, amount_cents: 11_113, date: Date.new(2026, 11, 20))

    expect { get_balance }.not_to change { [Balance.pluck(:id, :state), Payment.count] }
  end
end
