# frozen_string_literal: true

class DisputeEvidence::GenerateAccessActivityLogsService
  def self.perform(purchase)
    new(purchase).perform
  end

  include ActionView::Helpers::NumberHelper

  def initialize(purchase)
    @purchase = purchase
    @url_redirect = purchase.url_redirect
  end

  def perform
    [
      email_activity,
      rental_activity,
      usage_activity,
    ].compact.join("\n\n").presence
  end

  private
    attr_reader :purchase, :url_redirect

    def rental_activity
      return unless url_redirect.present? && url_redirect.rental_first_viewed_at.present?

      "The rented content was first viewed at #{url_redirect.rental_first_viewed_at}."
    end

    def usage_activity
      if consumption_events.any?
        generate_from_consumption_events
      elsif total_url_redirect_uses.positive?
        generate_from_url_redirect
      else
        nil
      end
    end

    # A bundle sale's disputed row is the wrapper purchase, but buyers download the member
    # products, so every access row is written against the members and the wrapper is always
    # silent. Aggregating both is what puts the download log back in the dispute packet
    # (gumroad-private#1690).
    def access_purchases
      @_access_purchases ||= bundle? ? [purchase, *purchase.product_purchases] : [purchase]
    end

    def bundle?
      purchase.is_bundle_purchase?
    end

    def consumption_events
      @_consumption_events ||= ConsumptionEvent
        .where(purchase_id: access_purchases.map(&:id))
        .order(:consumed_at, :id)
    end

    def total_url_redirect_uses
      @_total_url_redirect_uses ||= access_purchases.sum { _1.url_redirect&.uses.to_i }
    end

    def generate_from_url_redirect
      "The customer accessed the product #{total_url_redirect_uses} #{"time".pluralize(total_url_redirect_uses)}."
    end

    LOG_RECORDS_LIMIT = 10

    def generate_from_consumption_events
      [
        consumption_events_intro,
        consumption_event_row_attributes.join(","),
        consumption_event_rows
      ].flatten.join("\n")
    end

    def consumption_event_row_attributes
      BASE_ROW_ATTRIBUTES + (bundle? ? ["product"] : [])
    end

    BASE_ROW_ATTRIBUTES = %w(consumed_at event_type platform ip_address).freeze
    private_constant :BASE_ROW_ATTRIBUTES

    def consumption_event_rows
      consumption_events.first(LOG_RECORDS_LIMIT).map do |event|
        row = event.slice(*BASE_ROW_ATTRIBUTES).values
        row += [product_name_for(event)] if bundle?
        row.join(",")
      end
    end

    # Names the member a row belongs to, so a reviewer can tell which item of the bundle was
    # downloaded. Quoted because product names routinely contain commas.
    def product_name_for(event)
      name = purchase_names_by_id[event.purchase_id]
      name.present? ? "\"#{name.tr('"', "'")}\"" : ""
    end

    def purchase_names_by_id
      @_purchase_names_by_id ||= access_purchases.index_by(&:id).transform_values { _1.link&.name }
    end

    def consumption_events_intro
      count = consumption_events.count
      content = "The customer accessed the product #{count} #{"time".pluralize(count)}."
      if count > LOG_RECORDS_LIMIT
        content << " Most recent #{LOG_RECORDS_LIMIT} log records:"
      end
      content << "\n"
    end

    def email_activity
      receipt_email_info = purchase.receipt_email_info
      return unless receipt_email_info.present? && receipt_email_info.sent_at.present?

      content = "The receipt email was sent at #{receipt_email_info.sent_at}"
      content << ", delivered at #{receipt_email_info.delivered_at}" if receipt_email_info.delivered_at.present?
      content << ", opened at #{receipt_email_info.opened_at}" if receipt_email_info.opened_at.present?
      content << "."
    end
end
