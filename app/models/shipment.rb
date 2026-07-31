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
  # Scheme-insensitive because the stored prefixes are http for carriers that now serve https.
  # Returns nil rather than a guess: dispute evidence submits once, and a wrong number is worse
  # than an absent one.
  def carrier_and_tracking_number_from_url
    return if tracking_url.blank?

    url = tracking_url.sub(%r{\Ahttps?://}i, "")
    CARRIER_TRACKING_URL_MAPPING.each do |carrier_name, prefix|
      bare_prefix = prefix.sub(%r{\Ahttps?://}i, "")
      next unless url.start_with?(bare_prefix)

      number = url.delete_prefix(bare_prefix)
      return [carrier_name, number] if number.match?(/\A[A-Za-z0-9]+\z/)
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
