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
  # ten-digit remainder on a USPS URL is a DHL waybill someone pasted, not a USPS number, and the
  # shared alphanumeric bound this replaces could not tell the two apart.
  # Keys must mirror CARRIER_TRACKING_URL_MAPPING — a carrier with no entry derives nothing, and
  # the spec pins the parity rather than letting an evidence build raise over a missing key.
  CARRIER_TRACKING_NUMBER_FORMAT = {
    # 20/22-digit IMpb and its longer variants, or the 13-character S10 international form.
    "USPS" => /\A(?:\d{20}|\d{22}|\d{26}|\d{30}|\d{34}|[A-Za-z]{2}\d{9}[A-Za-z]{2})\z/,
    "UPS" => /\A1Z[A-Za-z0-9]{16}\z/i,
    "FedEx" => /\A(?:\d{12}|\d{15}|\d{20})\z/,
    "DHL" => /\A\d{10}\z/,
    # Bounds measured against production: every derivable value is 20–30 digits or GM + 18 digits.
    "DHL Global Mail" => /\A(?:\d{20,30}|[A-Za-z]{2}\d{18})\z/,
    "OnTrac" => /\A[A-Za-z0-9]{15}\z/,
    "Canada Post" => /\A\d{16}\z/
  }.freeze

  validates :purchase, presence: true

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
    return tracking_url if tracking_url.present?
    return nil if tracking_number.nil? || carrier.nil?
    return nil unless CARRIER_TRACKING_URL_MAPPING.key?(carrier)

    CARRIER_TRACKING_URL_MAPPING[carrier] + tracking_number
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
      format = CARRIER_TRACKING_NUMBER_FORMAT[carrier_name]
      return [carrier_name, number] if format && number.match?(format)
    end
    nil
  end

  private
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
