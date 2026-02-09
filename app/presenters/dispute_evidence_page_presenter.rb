# frozen_string_literal: true

class DisputeEvidencePagePresenter
  def initialize(dispute_evidence)
    @dispute_evidence = dispute_evidence
    @purchase = @dispute_evidence.disputable.purchase_for_dispute_evidence
    @purchase_product_presenter = PurchaseProductPresenter.new(@purchase)
  end

  def props
    {
      dispute_evidence: dispute_evidence_props,
      disputable: disputable_props,
      products: products_props,
    }
  end

  private
    attr_reader :dispute_evidence, :purchase, :purchase_product_presenter

    def dispute_evidence_props
      {
        dispute_reason: dispute_evidence.dispute.reason,
        customer_email: dispute_evidence.customer_email,
        purchased_at: dispute_evidence.purchased_at,
        duration_left_to_submit_evidence_formatted:,
        customer_communication_file_max_size: dispute_evidence.customer_communication_file_max_size,
        blobs: blobs_props
      }
    end

    def disputable_props
      {
        purchase_for_dispute_evidence_id: purchase.external_id,
        formatted_display_price: dispute_evidence.disputable.formatted_disputed_amount,
        is_subscription: purchase.subscription.present?
      }
    end

    def products_props
      dispute_evidence.disputable.disputed_purchases.map do |disputed_purchase|
        {
          name: disputed_purchase.link.name,
          url: disputed_purchase.link.long_url,
        }
      end
    end

    def duration_left_to_submit_evidence_formatted
      "#{dispute_evidence.hours_left_to_submit_evidence} hours"
    end

    def blobs_props
      {
        receipt_image: blob_props(dispute_evidence.receipt_image, "receipt_image"),
        policy_image: blob_props(dispute_evidence.policy_image, "policy_image"),
        customer_communication_file: blob_props(dispute_evidence.customer_communication_file, "customer_communication_file"),
      }
    end

    def blob_props(blob, type)
      return nil unless blob.attached?

      {
        byte_size: blob.byte_size,
        filename: blob.filename.to_s,
        key: blob.key,
        signed_id: nil,
        title: case type
               when "receipt_image" then "Receipt"
               when "policy_image" then "Refund policy"
               when "customer_communication_file" then "Customer communication"
               else type.humanize
               end,
      }
    end
end
