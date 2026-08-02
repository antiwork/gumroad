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
      [
        (generate_from_consumption_events if consumption_events.any?),
        (generate_from_url_redirect if unlogged_url_redirect_uses.positive?),
      ].compact.join("\n\n").presence
    end

    # The disputed row on a bundle sale is the wrapper, but access rows are written against the
    # member purchases the buyer actually downloads. Both are counted: the wrapper's own download
    # page still increments when no member is library-visible.
    def access_purchases
      @_access_purchases ||= if bundle?
        [purchase, *purchase.product_purchases.includes(:link, :url_redirect)]
      else
        [purchase]
      end
    end

    def bundle?
      purchase.is_bundle_purchase?
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
      BASE_ROW_ATTRIBUTES + (bundle? ? ["product"] : [])
    end

    def consumption_event_rows
      consumption_events.last(LOG_RECORDS_LIMIT).map do |event|
        row = event.slice(*BASE_ROW_ATTRIBUTES).values
        row += [product_name_for(event)] if bundle?
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

    # The ORIGINAL send dates the receipt: a resend is often triggered BY the
    # dispute, so citing the newest one would date the receipt after the
    # complaint. Later attempts are named separately rather than replacing it.
    def email_activity
      sends = purchase.receipt_email_infos.select { _1.sent_at.present? }
      return if sends.empty?

      return single_send_activity(sends.first) if sends.one?

      content = "The receipt email was sent at #{sends.first.sent_at}."
      content << " The receipt was sent again at #{sends.drop(1).map { _1.sent_at }.join('; ')}."
      content << unattributed_event_activity(sends)
    end

    def single_send_activity(email_info)
      content = "The receipt email was sent at #{email_info.sent_at}"
      content << ", delivered at #{email_info.delivered_at}" if email_info.delivered_at.present?
      content << ", opened at #{email_info.opened_at}" if email_info.opened_at.present?
      content << "."
    end

    # Providers give us no message identifier on a delivery or open event, so
    # with several sends outstanding we know a receipt was delivered and opened
    # but not WHICH send earned it — an event routes to the newest send that
    # predates it, which is a guess once two sends do. So report the earliest
    # of each across all sends and claim nothing per send: the card network
    # needs "it was delivered and read", and a per-send claim here would be
    # evidence we cannot stand behind. Tracked in gumroad-private#1635.
    def unattributed_event_activity(sends)
      delivered_at = sends.filter_map(&:delivered_at).min
      opened_at = sends.filter_map(&:opened_at).min

      content = +""
      content << " A receipt was delivered at #{delivered_at}." if delivered_at.present?
      content << " A receipt was opened at #{opened_at}." if opened_at.present?
      content
    end
end
