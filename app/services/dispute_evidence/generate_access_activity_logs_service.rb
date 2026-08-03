# frozen_string_literal: true

class DisputeEvidence::GenerateAccessActivityLogsService
  def self.perform(purchase, other_purchases: [])
    new(purchase, other_purchases:).perform
  end

  include ActionView::Helpers::NumberHelper

  def initialize(purchase, other_purchases: [])
    @purchase = purchase
    @other_purchases = other_purchases
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
    attr_reader :purchase, :other_purchases, :url_redirect

    def rental_activity
      return unless url_redirect.present? && url_redirect.rental_first_viewed_at.present?

      "The rented content was first viewed at #{url_redirect.rental_first_viewed_at}."
    end

    def usage_activity
      [
        (generate_from_consumption_events if consumption_events.any?),
        (generate_from_url_redirect if unlogged_url_redirect_uses.positive?),
      ].compact.join("\n\n").presence
    end

    # The disputed row on a bundle sale is the wrapper, but access rows are written against the
    # member purchases the buyer actually downloads. Both are counted: the wrapper's own download
    # page still increments when no member is library-visible.
    #
    # A combined charge is disputed as one amount, so the siblings count too: the representative is
    # chosen on refund policy and amount, never on access, and reporting only its activity told
    # Stripe "no access recorded" for orders the buyer demonstrably consumed elsewhere in the charge.
    def access_purchases
      @_access_purchases ||= [purchase, *other_purchases].flat_map { with_bundle_members(_1) }
    end

    def with_bundle_members(candidate)
      return [candidate] unless candidate.is_bundle_purchase?

      [candidate, *candidate.product_purchases.includes(:link, :url_redirect)]
    end

    # Name the product on each row once the log can span more than one of them, so an entry is
    # attributable to the purchase it came from rather than reading as the representative's.
    def attribute_products?
      access_purchases.size > 1
    end

    def consumption_events
      @_consumption_events ||= ConsumptionEvent
        .where(purchase_id: access_purchases.map(&:id))
        .order(:consumed_at, :id)
    end

    # A purchase's uses counter and its consumption events describe overlapping accesses, so only
    # event-less purchases contribute here — the old fallback, applied per purchase.
    def unlogged_url_redirect_uses
      @_unlogged_url_redirect_uses ||= begin
        event_logged_ids = consumption_events.map(&:purchase_id).to_set
        access_purchases.reject { event_logged_ids.include?(_1.id) }.sum { _1.url_redirect&.uses.to_i }
      end
    end

    def generate_from_url_redirect
      uses = unlogged_url_redirect_uses
      if consumption_events.any?
        "The customer accessed the product #{uses} more #{"time".pluralize(uses)}."
      else
        "The customer accessed the product #{uses} #{"time".pluralize(uses)}."
      end
    end

    LOG_RECORDS_LIMIT = 10

    def generate_from_consumption_events
      [
        consumption_events_intro,
        consumption_event_row_attributes.join(","),
        consumption_event_rows
      ].flatten.join("\n")
    end

    BASE_ROW_ATTRIBUTES = %w(consumed_at event_type platform ip_address).freeze

    def consumption_event_row_attributes
      BASE_ROW_ATTRIBUTES + (attribute_products? ? ["product"] : [])
    end

    def consumption_event_rows
      consumption_events.last(LOG_RECORDS_LIMIT).map do |event|
        row = event.slice(*BASE_ROW_ATTRIBUTES).values
        row += [product_name_for(event)] if attribute_products?
        row.join(",")
      end
    end

    # Quoted because product names routinely contain commas; embedded quotes are doubled per CSV
    # convention rather than rewritten, since this is evidence and the name must stay verbatim.
    def product_name_for(event)
      name = purchase_names_by_id[event.purchase_id]
      return "" if name.blank?

      "\"#{name.gsub("\"", "\"\"").gsub(/[\r\n]+/, " ")}\""
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
