# frozen_string_literal: true

require "spec_helper"

describe DisputeEvidencePagePresenter do
  let(:dispute_evidence) { create(:dispute_evidence, seller_contacted_at: 1.hour.ago) }
  let(:presenter) { described_class.new(dispute_evidence) }
  let(:purchase) { dispute_evidence.disputable.purchase_for_dispute_evidence }
  let(:purchase_product_presenter) { PurchaseProductPresenter.new(purchase) }

  describe "#props" do
    it "returns correct props" do
      receipt_image = dispute_evidence.receipt_image
      policy_image = dispute_evidence.policy_image

      expect(presenter.props[:dispute_evidence]).to eq(
        {
          dispute_reason: Dispute::REASON_FRAUDULENT,
          customer_email: dispute_evidence.customer_email,
          purchased_at: dispute_evidence.purchased_at,
          duration_left_to_submit_evidence_formatted: "71 hours",
          customer_communication_file_max_size: dispute_evidence.customer_communication_file_max_size,
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
          purchase_for_dispute_evidence_id: purchase.external_id,
          formatted_display_price: purchase.formatted_disputed_amount,
          is_subscription: purchase.subscription.present?
        }
      )
    end
  end
end
