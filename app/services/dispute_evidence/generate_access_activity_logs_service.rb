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
      elsif url_redirect.present? && url_redirect.uses.to_i.positive?
        generate_from_url_redirect
      else
        nil
      end
    end

    def consumption_events
      @_consumption_events ||= purchase.consumption_events.order(:consumed_at, :id)
    end

    def generate_from_url_redirect
      "The customer accessed the product #{url_redirect.uses} #{"time".pluralize(url_redirect.uses)}."
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
      %w(consumed_at event_type platform ip_address)
    end

    def consumption_event_rows
      consumption_events.first(LOG_RECORDS_LIMIT).map do
        _1.slice(*consumption_event_row_attributes).values.join(",")
      end
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
