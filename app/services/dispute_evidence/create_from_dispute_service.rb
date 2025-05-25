# frozen_string_literal: true

# Create a dispute_evidence record that will be submitted to Stripe
# Note that all files associated must not exceed 5MB
# https://support.stripe.com/questions/evidence-submission-troubleshooting-faq
#
class DisputeEvidence::CreateFromDisputeService
  include ProductsHelper

  def initialize(dispute)
    @dispute = dispute
    @purchase = dispute.disputable.purchase_for_dispute_evidence
  end

  def perform!
    product = purchase.link.paper_trail.version_at(purchase.created_at) || purchase.link
    shipment = purchase.shipment
    refund_policy_fine_print_view_events = find_refund_policy_fine_print_view_events(purchase)

    dispute_evidence = dispute.build_dispute_evidence
    dispute_evidence.purchased_at = purchase.created_at
    dispute_evidence.customer_purchase_ip = purchase.ip_address
    dispute_evidence.customer_email = purchase.email
    dispute_evidence.customer_name = purchase.full_name&.strip
    dispute_evidence.billing_address = build_billing_address(purchase)
    if shipment.present?
      dispute_evidence.shipping_address = dispute_evidence.billing_address
      dispute_evidence.shipped_at = shipment.shipped_at
      dispute_evidence.shipping_carrier = shipment.carrier
      dispute_evidence.shipping_tracking_number = shipment.tracking_number
    end
    dispute_evidence.product_description = generate_product_description(product:, purchase:)
    dispute_evidence.uncategorized_text = DisputeEvidence::GenerateUncategorizedTextService.perform(purchase)
    dispute_evidence.access_activity_log = DisputeEvidence::GenerateAccessActivityLogsService.perform(purchase)
    attach_receipt_image(dispute_evidence, purchase)

    dispute_evidence.policy_disclosure = generate_refund_policy_disclosure(purchase, refund_policy_fine_print_view_events)
    attach_refund_policy_image(dispute_evidence, purchase, open_fine_print_modal: refund_policy_fine_print_view_events.any?)

    dispute_evidence.save!

    if dispute_evidence.customer_communication_file_max_size < DisputeEvidence::MINIMUM_RECOMMENDED_CUSTOMER_COMMUNICATION_FILE_SIZE
      Bugsnag.notify(
        "DisputeEvidence::CreateFromDisputeService - Allowed file size on dispute evidence #{dispute_evidence.id} for " \
        "customer_communication_file is too low: " + number_to_human_size(dispute_evidence.customer_communication_file_max_size)
      )
    end

    dispute_evidence
  end

  private
    attr_reader :dispute, :purchase

    def build_billing_address(purchase)
      fields = %w(street_address city state zip_code country)
      fields.map { |field| purchase.send(field) }.compact.join(", ")
    end

    def generate_product_description(product:, purchase:)
      type = product.native_type || Link::NATIVE_TYPE_DIGITAL

      rows = []
      rows << "Product name: #{product.name}"
      rows << "Product as seen when purchased: #{Rails.application.routes.url_helpers.purchase_product_url(purchase.external_id, host: DOMAIN, protocol: PROTOCOL)}"
      rows << "Product type: #{product.is_physical? ? "physical product" : type}"
      rows << "Product variant: #{variant_names_displayable(purchase.variant_names)}" if purchase.variant_names.present?
      rows << "Quantity purchased: #{purchase.quantity}" if purchase.quantity > 1
      rows << "Receipt: #{purchase.receipt_url}"
      rows << "Live product: #{purchase.link.long_url}"
      rows.join("\n")
    end

    def attach_receipt_image(dispute_evidence, purchase)
      image = DisputeEvidence::GenerateReceiptImageService.perform(purchase)

      unless image
        Bugsnag.notify("CreateFromDisputeService: Could not generate receipt_image for purchase ID #{purchase.id}")
        return
      end

      dispute_evidence.receipt_image.attach(
        io: StringIO.new(image),
        filename: "receipt_image.jpg",
        content_type: "image/jpeg"
      )
    end

    def generate_refund_policy_disclosure(purchase, events)
      return if events.none?

      "The refund policy modal has been viewed by the customer #{events.count} #{"time".pluralize(events.count)}" \
      " before the purchase was made at #{purchase.created_at}.\n" \
      "Timestamp information of the #{"view".pluralize(events.count)}: #{events.map(&:created_at).join(", ")}\n\n" \
      "Internal browser GUID for reference: #{purchase.browser_guid}"
    end

    def attach_refund_policy_image(dispute_evidence, purchase, open_fine_print_modal:)
      return unless purchase.purchase_refund_policy.present?

      url = Rails.application.routes.url_helpers.purchase_product_url(
        purchase.external_id,
        host: DOMAIN,
        protocol: PROTOCOL,
        anchor: open_fine_print_modal ? "refund-policy" : nil
      )
      binary_data = DisputeEvidence::GenerateRefundPolicyImageService.perform(
        url:,
        mobile_purchase: mobile_purchase?,
        open_fine_print_modal:,
        max_size_allowed: dispute_evidence.policy_image_max_size
      )
      dispute_evidence.policy_image.attach(
        io: StringIO.new(binary_data),
        filename: "refund_policy.jpg",
        content_type: "image/jpeg"
      )
    rescue DisputeEvidence::GenerateRefundPolicyImageService::ImageTooLargeError
      Bugsnag.notify("DisputeEvidence::CreateFromDisputeService (purchase #{purchase.id}): Refund policy image not attached because was too large")
    end

    def mobile_purchase?
      purchase.is_mobile?
    end

    def find_refund_policy_fine_print_view_events(purchase)
      @_events ||= Event.where(link_id: purchase.link_id)
        .where(browser_guid: purchase.browser_guid)
        .where("created_at < ?", purchase.created_at)
        .where(event_name: Event::NAME_PRODUCT_REFUND_POLICY_FINE_PRINT_VIEW)
        .order(id: :asc)
    end
end
