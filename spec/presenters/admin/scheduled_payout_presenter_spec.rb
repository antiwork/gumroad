# frozen_string_literal: true

require "spec_helper"

describe Admin::ScheduledPayoutPresenter do
  describe "#props" do
    it "returns the existing scheduled payout shape without enrichment" do
      seller = create(:compliant_user, email: "seller@example.com", name: "Seller One")
      created_by = create(:admin_user, name: "Admin One")
      scheduled_payout = create(:scheduled_payout, user: seller, created_by:)

      expect(described_class.new(scheduled_payout:).props).to eq(
        external_id: scheduled_payout.external_id,
        action: scheduled_payout.action,
        status: scheduled_payout.status,
        delay_days: scheduled_payout.delay_days,
        scheduled_at: scheduled_payout.scheduled_at,
        executed_at: scheduled_payout.executed_at,
        payout_amount_cents: scheduled_payout.payout_amount_cents,
        created_at: scheduled_payout.created_at,
        user: {
          external_id: seller.external_id,
          email: seller.form_email,
          name: "Seller One"
        },
        created_by: { name: "Admin One" }
      )
    end

    it "adds enrichment without changing existing keys" do
      scheduled_payout = create(:scheduled_payout)
      enrichment = {
        product_count: 2,
        incoming_affiliate_count: 3,
        risk_state: { status: "Compliant" },
        top_categories: [{ slug: "design", product_count: 2 }],
        unpaid_balance_cents: 12_345,
        unpaid_balance_formatted: "$123.45",
      }
      original_props = described_class.new(scheduled_payout:).props

      enriched_props = described_class.new(scheduled_payout:, enrichment:).props

      expect(enriched_props.except(*enrichment.keys)).to eq(original_props)
      expect(enriched_props).to include(enrichment)
    end
  end
end
