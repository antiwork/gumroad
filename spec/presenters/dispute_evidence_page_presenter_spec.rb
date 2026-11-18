# frozen_string_literal: true

require "spec_helper"

describe DisputeEvidencePagePresenter do
  include_context "without the weekend window extension"

  let(:dispute_evidence) { create(:dispute_evidence, seller_contacted_at: 1.hour.ago) }
  let(:purchase) { dispute_evidence.disputable.purchase_for_dispute_evidence }
  let(:purchase_route_id) { purchase.external_id }
  let(:presenter) { described_class.new(dispute_evidence, purchase_route_id:) }
  let(:purchase_product_presenter) { PurchaseProductPresenter.new(purchase) }

  describe "a window that touches a weekend" do
    before { stub_const("DisputeEvidence::WEEKEND_EXTENSION_STARTS_AT", Time.utc(2026, 10, 5)) }

    it "quotes the extended hours and due time" do
      saturday = Time.utc(2026, 10, 10, 16, 18)
      dispute_evidence.update!(seller_contacted_at: saturday)

      travel_to(saturday + 1.hour) do
        props = presenter.props[:dispute_evidence]

        expect(props[:duration_left_to_submit_evidence_formatted]).to eq("119 hours")
        expect(props[:seller_response_due_at]).to eq(Time.utc(2026, 10, 15, 16, 18).iso8601)
      end
    end
  end

  describe "#props" do
    it "returns correct props" do
      dispute_evidence.dispute.update!(processor_amount_cents: 1_00, processor_currency: Currency::USD)
      receipt_image = dispute_evidence.receipt_image
      policy_image = dispute_evidence.policy_image

      expect(presenter.props[:dispute_evidence]).to eq(
        {
          dispute_reason: Dispute::REASON_FRAUDULENT,
          customer_email: dispute_evidence.customer_email,
          purchased_at: dispute_evidence.purchased_at,
          duration_left_to_submit_evidence_formatted: "71 hours",
          seller_response_due_at: dispute_evidence.seller_response_due_at.iso8601,
          below_contest_minimum: true,
          seller_submitted: false,
          formatted_dispute_amount: nil,
          customer_communication_file_max_size: dispute_evidence.customer_communication_file_max_size,
          customer_communication_files_max_count: DisputeEvidence::MAX_CUSTOMER_COMMUNICATION_FILES,
          blobs: {
            receipt_image: {
              byte_size: receipt_image.byte_size,
              filename: receipt_image.filename.to_s,
              key: receipt_image.key,
              signed_id: nil,
              title: "Receipt",
            },
            policy_image: {
              byte_size: policy_image.byte_size,
              filename: policy_image.filename.to_s,
              key: policy_image.key,
              signed_id: nil,
              title: "Refund policy",
            },
            customer_communication_file: nil,
          },
          saved: {
            reason_for_winning: nil,
            cancellation_rebuttal: nil,
            refund_refusal_explanation: nil,
          }
        }
      )

      expect(presenter.props[:products]).to eq(
        [{
          name: purchase_product_presenter.product_props[:product][:name],
          url: purchase_product_presenter.product_props[:product][:long_url],
        }]
      )

      expect(presenter.props[:disputable]).to eq(
        {
          purchase_for_dispute_evidence_id: purchase_route_id,
          formatted_display_price: purchase.formatted_disputed_amount,
          is_subscription: purchase.subscription.present?
        }
      )
    end

    it "does not flag a dispute at the contest minimum as below it" do
      dispute = create(:dispute_formalized, purchase: create(:purchase, link: create(:product, price_cents: FightDisputeJob::MINIMUM_CONTESTED_AMOUNT_CENTS)),
                                            processor_amount_cents: FightDisputeJob::MINIMUM_CONTESTED_AMOUNT_CENTS, processor_currency: Currency::USD)
      dispute_evidence = create(:dispute_evidence, dispute:)

      props = described_class.new(dispute_evidence, purchase_route_id: dispute.purchase.external_id).props[:dispute_evidence]

      expect(props[:below_contest_minimum]).to be(false)
    end
  end
end
