# frozen_string_literal: true

# A counter-notice comes back to the address the notice was sent from. Recording it starts the
# restoration clock, so the record and the email that tells the seller about it are one step.
class PiracyReports::CounterNoticeService
  Result = Struct.new(:report, :errors, keyword_init: true) do
    def success?
      errors.empty?
    end
  end

  # `received_at` is the date the host received the counter-notice, which is what the restoration
  # window runs from. It is not the date the mail reached support@.
  def initialize(report:, body:, received_at: Time.current)
    @report = report
    @body = body.to_s.strip
    @received_at = received_at
  end

  def call
    result = report.with_lock { record }
    return result unless result.success?

    PiracyReportMailer.counter_notice_received(report.id).deliver_later
    result
  end

  private
    attr_reader :report, :body, :received_at

    def record
      errors = []
      errors << "The report has no notice out" unless report.sent?
      errors << "The counter-notice is empty" if body.blank?
      return Result.new(report:, errors:) if errors.any?

      report.assign_attributes(
        counter_notice_body: body,
        counter_notice_received_at: received_at,
        counter_notice_forwarded_at: Time.current
      )
      report.receive_counter_notice!
      Result.new(report:, errors: [])
    rescue StateMachines::InvalidTransition => e
      Result.new(report:, errors: [e.message])
    end
end
