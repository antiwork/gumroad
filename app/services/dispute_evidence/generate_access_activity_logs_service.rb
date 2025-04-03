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

    def email_activity
      receipt_email_info = purchase.receipt_email_info
      return unless receipt_email_info.present? && receipt_email_info.sent_at.present?

      content = "The receipt email was sent at #{receipt_email_info.sent_at}"
      content << ", delivered at #{receipt_email_info.delivered_at}" if receipt_email_info.delivered_at.present?
      content << ", opened at #{receipt_email_info.opened_at}" if receipt_email_info.opened_at.present?
      content << "."
    end
end
