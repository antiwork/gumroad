# frozen_string_literal: true

class DisputeEvidence::GenerateUncategorizedTextService
  def self.perform(purchase)
    new(purchase).perform
  end

  include ActionView::Helpers::NumberHelper

  # Comfortably past the longest URL any mapped carrier issues; past it the value is paste garbage
  # rather than a link, and this field is shared with every other row we send.
  MAX_TRACKING_URL_LENGTH = 500

  attr_reader :purchase

  def initialize(purchase)
    @purchase = purchase
  end

  def perform
    rows = [
      customer_location_text,
      billing_zip_text,
      shipping_tracking_text,
      previous_purchases_rows
    ].compact
    rows.flatten.join("\n")
  end

  private
    def customer_location_text
      return if purchase.ip_state.blank?

      "Device location: #{purchase.ip_state}, #{purchase.ip_country}"
    end

    def billing_zip_text
      return if purchase.credit_card_zipcode.blank?

      "Billing postal code: #{purchase.credit_card_zipcode}"
    end

    # Always include the URL: the structured fields only carry it when a known carrier can be
    # attributed, and we get one submission. Labelled as the seller's because every other row here
    # is our own assertion.
    def shipping_tracking_text
      tracking_url = submission_safe_tracking_url
      return if tracking_url.nil?

      "Seller-provided shipment tracking URL: #{tracking_url}"
    end

    # `shipments.tracking_url` is a free-text param no controller validates, so a value carrying a
    # newline would put seller-written lines into evidence Stripe reads as Gumroad's own. Dropping
    # an unusable row costs less than vouching for its text.
    def submission_safe_tracking_url
      # Same gate as CreateFromDisputeService#shipment_for: a shipment row predating Shipment's
      # create-time validation can hang off a digital purchase, and its URL is shipping evidence too.
      return unless purchase.required_delivery_at_checkout?

      # `scrub` before `strip`: on an invalid byte sequence `strip` raises
      # `Encoding::CompatibilityError` before any guard below runs, failing the whole evidence
      # build rather than dropping one unusable row.
      url = purchase.shipment&.tracking_url&.scrub&.strip
      return if url.blank? || url.length > MAX_TRACKING_URL_LENGTH || url.match?(/[[:cntrl:]]/)

      parsed = begin
        URI.parse(url)
      rescue URI::InvalidURIError
        nil
      end
      return unless parsed.is_a?(URI::HTTP) && parsed.host.present?
      # Credentials would be secrets of the seller's we should not forward, and they read as part
      # of the hostname to anyone skimming the evidence.
      return if parsed.userinfo.present?

      url
    end

    # Evidence of one or more non-disputed payments on the same card
    def previous_purchases_rows
      previous_purchases = find_previous_purchases
      return if previous_purchases.none?

      rows = []
      rows << "\nPrevious undisputed #{"purchase".pluralize(previous_purchases.count)} on Gumroad:"
      previous_purchases.each do |other_purchase|
        rows << previous_purchases_text(other_purchase)
      end
      rows
    end

    def previous_purchases_text(other_purchase)
      device_location = build_device_location(other_purchase)
      [
        other_purchase.created_at,
        MoneyFormatter.format(other_purchase.total_transaction_cents, :usd),
        other_purchase.full_name&.strip,
        other_purchase.email,
        ("Billing postal code: #{other_purchase.credit_card_zipcode}" if other_purchase.credit_card_zipcode.present?),
        ("Device location: #{device_location}" if device_location.present?),
      ].compact.join(", ")
    end

    def build_device_location(purchase)
      [purchase.ip_address, purchase.ip_state, purchase.ip_country].compact.join(", ").presence
    end

    def find_previous_purchases
      Purchase.successful
        .not_fully_refunded
        .not_chargedback
        .where(stripe_fingerprint: purchase.stripe_fingerprint)
        .where.not(id: purchase.id)
        .order(created_at: :desc)
        .limit(10)
    end
end
