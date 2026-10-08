# frozen_string_literal: true

# Records a counter-notice and forwards it to the seller at once. The restoration window runs from
# the date the host received it, which can differ from the day it reached us.
class PiracyReports::CounterNoticeService
  Result = Struct.new(:report, :errors, keyword_init: true) do
    def success?
      errors.empty?
    end
  end

  def initialize(report:, body:, received_on:)
    @report = report
    @body = body.to_s.strip
    @received_on = received_on
  end

  # forwarded_at is set only once the seller email is queued, so a retry after a failed queue
  # finishes the forward instead of being refused as a duplicate.
  def call
    result = report.with_lock { record }
    return result unless result.success?

    PiracyReportMailer.counter_notice_received(report.id).deliver_later
    report.update!(counter_notice_forwarded_at: Time.current)
    result
  end

  private
    attr_reader :report, :body, :received_on

    def record
      if report.counter_noticed?
        return Result.new(report:, errors: []) if report.counter_notice_forwarded_at.nil?

        return Result.new(report:, errors: ["A counter-notice is already recorded for this report"])
      end
      return Result.new(report:, errors: ["The report has no notice out with a host"]) unless open_to_counter_notice?

      date = parsed_received_on
      errors = []
      errors << "body is required" if body.blank?
      errors << "body is too long" if body.length > PiracyReport::MAX_COUNTER_NOTICE_LENGTH || body.bytesize > PiracyReport::MAX_COUNTER_NOTICE_BYTES
      errors << "received_on must be a YYYY-MM-DD date between the send date and today" unless date&.between?(earliest_receipt_date, latest_receipt_date)
      return Result.new(report:, errors:) if errors.any?

      report.assign_attributes(
        counter_notice_body: body, counter_notice_received_on: date, counter_notice_forwarded_at: nil,
        outcome: nil, outcome_reason: nil, resolved_at: nil, outcome_notified_at: nil
      )
      report.receive_counter_notice!
      Result.new(report:, errors: [])
    end

    def open_to_counter_notice?
      report.sent? || (report.resolved? && PiracyReport::REOPENABLE_OUTCOMES.include?(report.outcome))
    end

    # The host's local date can be a day behind or ahead of the UTC dates stored here.
    def earliest_receipt_date
      report.sent_at.to_date.prev_day
    end

    def latest_receipt_date
      Date.current.next_day
    end

    def parsed_received_on
      value = received_on.to_s
      Date.iso8601(value) if value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    rescue Date::Error
      nil
    end
end
