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
    shipment, shipped_purchase = evidence_shipment_and_purchase
    refund_policy_fine_print_view_events = find_refund_policy_fine_print_view_events(purchase)
    purchase_at_checkout = purchase_as_at_checkout

    dispute_evidence = dispute.build_dispute_evidence
    dispute_evidence.purchased_at = purchase.created_at
    dispute_evidence.customer_purchase_ip = purchase.ip_address
    dispute_evidence.customer_email = purchase_at_checkout.email
    dispute_evidence.customer_name = purchase_at_checkout.full_name&.strip
    # Left blank deliberately. The columns below are the buyer's SHIPPING address; the card's own
    # billing address never reaches us as structured data (only `credit_card_zipcode`, which the
    # uncategorized text carries). Sending a shipping address in this slot asserts to the network
    # that we hold billing details we do not.
    dispute_evidence.billing_address = nil
    if shipment.present?
      dispute_evidence.shipping_address = build_shipping_address(as_at_checkout(shipped_purchase))
      dispute_evidence.shipped_at = shipment.shipped_at
      dispute_evidence.shipping_carrier, dispute_evidence.shipping_tracking_number =
        carrier_and_tracking_number(shipment)
    end
    dispute_evidence.product_description = generate_product_description(product:, purchase:)
    dispute_evidence.uncategorized_text = DisputeEvidence::GenerateUncategorizedTextService.perform(purchase)
    dispute_evidence.access_activity_log = DisputeEvidence::GenerateAccessActivityLogsService.perform(purchase, other_purchases: other_disputed_purchases)
    attach_receipt_image(dispute_evidence, purchase)

    dispute_evidence.policy_disclosure = generate_refund_policy_disclosure(purchase, refund_policy_fine_print_view_events)
    attach_refund_policy_image(dispute_evidence, purchase, open_fine_print_modal: refund_policy_fine_print_view_events.any?)

    dispute_evidence.save!

    if dispute_evidence.customer_communication_file_max_size < DisputeEvidence::MINIMUM_RECOMMENDED_CUSTOMER_COMMUNICATION_FILE_SIZE
      ErrorNotifier.notify(
        "DisputeEvidence::CreateFromDisputeService - Allowed file size on dispute evidence #{dispute_evidence.id} for " \
        "customer_communication_file is too low: " + number_to_human_size(dispute_evidence.customer_communication_file_max_size)
      )
    end

    dispute_evidence
  end

  private
    attr_reader :dispute, :purchase

    # The address and buyer identity we submit must be what the buyer entered at checkout: three
    # seller-facing writers mutate these columns afterwards, so a live read presents mutable
    # operational data to a card network as platform-generated evidence. Falls back to the live
    # record when no version covers the purchase, which is today's behaviour.
    def as_at_checkout(source)
      @_as_at_checkout ||= {}
      @_as_at_checkout[source.id] ||= source.paper_trail.version_at(source.created_at) || source
    end

    def purchase_as_at_checkout
      as_at_checkout(purchase)
    end

    def other_disputed_purchases
      @_other_disputed_purchases ||= dispute.disputable.disputed_purchases.reject { _1.id == purchase.id }
    end

    def build_shipping_address(source)
      fields = %w(street_address city state zip_code country)
      fields.map { |field| source.send(field) }.compact.join(", ")
    end

    # A shipment row alone does not mean the order needed delivery: rows predating Shipment's
    # create-time gate hang off digital purchases, and their evidence would put a shipping claim
    # into a digital-product dispute — an assertion the buyer can trivially disprove, on our
    # single submission. Checked as at checkout, not live: a seller disabling shipping later
    # must not erase delivery proof for an order that genuinely shipped.
    def shipment_for(purchase)
      shipment = purchase.shipment
      return if shipment.blank?
      return unless purchase.required_delivery_at_checkout?

      shipment
    end

    # Fill the shipping slots from whichever constituent purchase actually shipped, independently of
    # which one `purchase_for_dispute_evidence` picked for identity and refund policy — that ranking
    # never looks at shipments, so on a combined charge where the representative ships nothing and a
    # sibling does, all four structured slots went out empty while the sibling's tracking sat in free
    # text. Stripe reads the structured fields, and we submit once. Representative first so the
    # single-purchase and already-correct cases are unchanged; ties among siblings break on id.
    #
    # Returns the pair, because the address slot must come from the purchase that shipped and
    # re-deriving it from `shipment.purchase` would ask the database for a row we already hold.
    def evidence_shipment_and_purchase
      return @_evidence_shipment_and_purchase if defined?(@_evidence_shipment_and_purchase)

      candidates = [purchase, *other_disputed_purchases.sort_by(&:id)]
      @_evidence_shipment_and_purchase =
        candidates.lazy.map { [shipment_for(_1), _1] }.find { _1.first.present? } || [nil, nil]
    end

    def evidence_shipment
      evidence_shipment_and_purchase.first
    end

    # Sellers only ever supply a tracking URL, so derive from it when the columns are blank —
    # which in production they always are. Taken as a pair: falling back per-field would pair a
    # legacy row's carrier with a number derived from a different carrier's URL.
    def carrier_and_tracking_number(shipment)
      if shipment.carrier.present? && shipment.tracking_number.present?
        [shipment.carrier, shipment.tracking_number]
      else
        shipment.carrier_and_tracking_number_from_url
      end
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
      rows.concat(other_disputed_items_rows)
      rows.join("\n")
    end

    # A combined charge is disputed as one amount, but the structured evidence fields above
    # describe only the representative purchase `purchase_for_dispute_evidence` picked. Listing
    # the rest keeps the description honest about what the disputed amount covers — otherwise the
    # network sees one item argued against a larger charge, which reads as a partial answer.
    # Their own shipping details cannot go in the structured slots: Stripe holds one carrier,
    # one tracking number and one shipping date per dispute, and we submit once.
    def other_disputed_items_rows
      other_purchases = other_disputed_purchases
      return [] if other_purchases.empty?

      rows = ["", "This charge also covers #{other_purchases.size} other #{"item".pluralize(other_purchases.size)}:"]
      other_purchases.each do |other|
        details = ["Product name: #{other.link.name}"]
        details << "Quantity purchased: #{other.quantity}" if other.quantity > 1
        shipment = shipment_for(other)
        if shipment&.shipped_at.present?
          carrier, tracking_number = carrier_and_tracking_number(shipment)
          details << "Shipped on #{shipment.shipped_at.to_fs(:formatted_date_full_month)}"
          details << "Carrier: #{carrier}" if carrier.present?
          details << "Tracking number: #{tracking_number}" if tracking_number.present?
        end
        rows << details.join(", ")
      end
      rows
    end

    def attach_receipt_image(dispute_evidence, purchase)
      image = DisputeEvidence::GenerateReceiptImageService.perform(purchase)

      unless image
        ErrorNotifier.notify("CreateFromDisputeService: Could not generate receipt_image for purchase ID #{purchase.id}")
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
      ErrorNotifier.notify("DisputeEvidence::CreateFromDisputeService (purchase #{purchase.id}): Refund policy image not attached because was too large")
    rescue => e
      ErrorNotifier.notify(e, context: { service: "DisputeEvidence::CreateFromDisputeService#attach_refund_policy_image", purchase_id: purchase.id })
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
