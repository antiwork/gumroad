# frozen_string_literal: true

class Shipment < ApplicationRecord
  belongs_to :purchase, optional: true

  CARRIER_TRACKING_URL_MAPPING = {
    "USPS" => "https://tools.usps.com/go/TrackConfirmAction?qtc_tLabels1=",
    "UPS" => "http://wwwapps.ups.com/WebTracking/processInputRequest?TypeOfInquiryNumber=T&InquiryNumber1=",
    "FedEx" => "http://www.fedex.com/Tracking?language=english&cntry_code=us&tracknumbers=",
    "DHL" => "http://www.dhl.com/content/g0/en/express/tracking.shtml?brand=DHL&AWB=",
    "DHL Global Mail" => "http://webtrack.dhlglobalmail.com/?trackingnumber=",
    "OnTrac" => "http://www.ontrac.com/trackres.asp?tracking_number=",
    "Canada Post" => "https://www.canadapost.ca/cpotools/apps/track/personal/findByTrackNumber?LOCALE=en&trackingNumber="
  }.freeze

  # The formats each mapped carrier issues. Reaching a carrier's tracking form is not enough: a
  # ten-digit remainder on the USPS form is a DHL waybill someone pasted, not a USPS number.
  # Keys must mirror CARRIER_TRACKING_URL_MAPPING — a carrier with no entry derives nothing, and
  # the spec pins the parity rather than letting an evidence build raise over a missing key.
  CARRIER_TRACKING_NUMBER_FORMAT = {
    # 20/22-digit IMpb and its longer variants, or the 13-character S10 international form.
    "USPS" => /\A(?:\d{20}|\d{22}|\d{26}|\d{30}|\d{34}|[A-Za-z]{2}\d{9}[A-Za-z]{2})\z/,
    "UPS" => /\A1Z[A-Za-z0-9]{16}\z/i,
    "FedEx" => /\A(?:\d{12}|\d{15}|\d{20})\z/,
    "DHL" => /\A\d{10}\z/,
    # DHL eCommerce publishes no crisp format, so the range is deliberately wider than the
    # 20/22/26/30-digit and two-letter-plus-18-digit values production actually shows.
    "DHL Global Mail" => /\A(?:\d{20,30}|[A-Za-z]{2}\d{18})\z/,
    "OnTrac" => /\A[A-Za-z0-9]{15}\z/,
    "Canada Post" => /\A\d{16}\z/
  }.freeze

  # Whitespace the seller pasted, percent-encoded by the browser before it reached the column.
  # `%20` leads 1,932 of the newest 200,000 shipments' USPS numbers; without trimming it the
  # number never matches its carrier's format and the strongest evidence we hold is dropped.
  PERCENT_ENCODED_WHITESPACE = /\A(?:%(?:20|09|0[AaDd]))+|(?:%(?:20|09|0[AaDd]))+\z/

  TRACKING_LINK_MAX_LENGTH = 2_083
  TRACKING_LINK_SCHEMES = %w[http https].freeze
  TRACKING_LINK_CONTROL_CHARACTER_REGEX = /[[:cntrl:]]/
  TRACKING_LINK_NON_ASCII_REGEX = /[^\x00-\x7F]/
  VALID_TRACKING_LINK_MESSAGE = "must be a full URL beginning with http:// or https://"

  # Rails humanizes this to "Tracking url", which reads as a typo in a message we show sellers.
  def self.human_attribute_name(attr, _)
    case attr
    when "tracking_url" then "Tracking URL"
    else super
    end
  end

  validates :purchase, presence: true
  before_validation :strip_tracking_url
  validate :tracking_url_must_be_display_safe
  # Create-only: violating rows already exist and must stay updatable (`mark_shipped!` is an
  # update). Ungated, a shipment on a digital purchase injects shipping evidence into a
  # digital-product dispute and emails the buyer "Your order has shipped". Checkout-time, not
  # live: a seller flipping shipping on later must not authorize a false shipment on an old
  # digital order, and flipping it off must not block shipping an order that owes delivery.
  validate :purchase_requires_shipping, on: :create

  # The purchase's updated_at should reflect changes to its shipment.
  after_update :touch_purchase

  state_machine(:ship_state, initial: :not_shipped) do
    after_transition not_shipped: :shipped, do: :marked_as_shipped!
    after_transition not_shipped: :shipped, do: :notify_buyer_of_shipment

    event :mark_shipped do
      transition not_shipped: :shipped
    end
  end

  def shipped?
    shipped_at.present?
  end

  def calculated_tracking_url
    tracking_link_for_display&.fetch(:url)
  end

  def tracking_link_for_display
    display_safe_tracking_link = self.class.display_safe_tracking_link(raw_tracking_link)
    return if display_safe_tracking_link.blank?

    # A carrier hostname alone must not earn the trusted label — https://tools.usps.com/anything is
    # still a seller-chosen destination. Trust only a link we derived ourselves (tracking_url blank)
    # or a stored URL whose carrier form and tracking number both verify.
    verified_carrier_link = tracking_url.blank? || carrier_and_tracking_number_from_url.present?

    {
      url: display_safe_tracking_link,
      label: verified_carrier_link ? "Track your package" : "Seller-provided tracking link",
      host: verified_carrier_link ? nil : self.class.parsed_tracking_uri(display_safe_tracking_link).host.downcase,
    }
  end

  def self.display_safe_tracking_link(value)
    normalized_value = value.to_s.strip
    return if normalized_value.blank?
    return if normalized_value.length > TRACKING_LINK_MAX_LENGTH
    return if normalized_value.match?(TRACKING_LINK_CONTROL_CHARACTER_REGEX)

    uri = parsed_tracking_uri(normalized_value)
    return unless TRACKING_LINK_SCHEMES.include?(uri.scheme&.downcase)
    return if uri.host.blank?
    return if uri.userinfo.present?

    normalized_value
  rescue URI::InvalidURIError
    nil
  end

  # URI.parse rejects the multibyte URLs sellers paste from international carrier pages, so
  # non-ASCII is escaped for parsing only — the stored and rendered value stays as typed.
  def self.parsed_tracking_uri(value)
    URI.parse(value.gsub(TRACKING_LINK_NON_ASCII_REGEX) { |character| URI::DEFAULT_PARSER.escape(character) })
  end

  # `carrier` and `tracking_number` have no seller-facing writer — every such path sets only
  # `tracking_url` — so read them back out of the URL when it is one of the forms above.
  # A scheme is required: the column also holds bare tracking numbers and free-text notes, and
  # without it any text shaped like a carrier host would be promoted to structured evidence.
  # Host is folded but the path and query keys are compared exactly, because their casing is
  # significant to the carrier — `QTC_TLABELS1` is not a form USPS serves.
  # Returns nil rather than a guess: dispute evidence submits once, and a wrong number is worse
  # than an absent one, so the remainder must match a format that carrier issues.
  def carrier_and_tracking_number_from_url
    # No writer strips this column, and the free-text evidence path strips before using it; without
    # the same treatment here a trailing space would cost the structured pair but keep the URL row.
    # `scrub` first because it is free text: on an invalid byte sequence `strip` raises
    # `Encoding::CompatibilityError` (and the regex below `ArgumentError`), failing the whole
    # evidence build rather than skipping one unusable field.
    url = tracking_url&.scrub&.strip
    return if url.blank?

    schemeless = url[%r{\Ahttps?://(.+)\z}i, 1]
    return if schemeless.nil?

    url_host, slash, url_rest = schemeless.partition("/")
    return if slash.empty?

    CARRIER_TRACKING_URL_MAPPING.each do |carrier_name, prefix|
      prefix_host, _, prefix_rest = prefix.sub(%r{\Ahttps?://}i, "").partition("/")
      next unless url_host.casecmp?(prefix_host)
      next unless url_rest.start_with?(prefix_rest)

      number = url_rest[prefix_rest.length..]
      # Two passes: one value can carry an encoded token at each end.
      number = number.sub(PERCENT_ENCODED_WHITESPACE, "").sub(PERCENT_ENCODED_WHITESPACE, "")
      format = CARRIER_TRACKING_NUMBER_FORMAT[carrier_name]
      return [carrier_name, number] if format && number.match?(format)
    end
    nil
  end

  private
    def raw_tracking_link
      return tracking_url if tracking_url.present?
      return if tracking_number.blank? || carrier.blank?
      return unless CARRIER_TRACKING_URL_MAPPING.key?(carrier)

      CARRIER_TRACKING_URL_MAPPING[carrier] + tracking_number
    end

    def strip_tracking_url
      self.tracking_url = tracking_url.strip if will_save_change_to_tracking_url? && tracking_url.present?
    end

    def tracking_url_must_be_display_safe
      # Existing shipments have free-text values; reject only new writes so those rows stay editable.
      return unless will_save_change_to_tracking_url? && tracking_url.present?
      return if self.class.display_safe_tracking_link(tracking_url).present?

      errors.add(:tracking_url, VALID_TRACKING_LINK_MESSAGE)
    end

    def purchase_requires_shipping
      return if purchase.blank?
      return if purchase.required_delivery_at_checkout?

      errors.add(:purchase, "does not require shipping")
    end

    def marked_as_shipped!
      update!(shipped_at: Time.current)
    end

    def notify_buyer_of_shipment
      SentEmailInfo.ensure_mailer_uniqueness("CustomerLowPriorityMailer",
                                             "order_shipped",
                                             id) do
        CustomerLowPriorityMailer.order_shipped(id).deliver_later(queue: "low")
      end
    end

    def touch_purchase
      purchase.touch
    end
end
