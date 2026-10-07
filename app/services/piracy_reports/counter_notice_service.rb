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
  # window runs from. It is not the date the reply reached support@, so it has no default: a guess
  # would start the seller's clock in the wrong place, and a late entry would start it too late.
  def initialize(report:, body:, received_at:)
    @report = report
    @body = body.to_s.strip
    @received_at = received_at
  end

  def call
    # A counter-notice that is on the record but was never forwarded is the one case worth running
    # again: the clock is already right, so this only sends the warning the seller is still owed.
    return deliver if recorded_but_not_forwarded?

    result = report.with_lock { record }
    return result unless result.success?

    deliver
  end

  private
    attr_reader :report, :body, :received_at

    def recorded_but_not_forwarded?
      report.counter_noticed? && report.counter_notice_forwarded_at.nil?
    end

    def record
      errors = []
      errors << "The report has no notice out" unless report.sent?
      errors << "The counter-notice is empty" if body.blank?
      errors << "The counter-notice has no received date" if received_at.blank?
      return Result.new(report:, errors:) if errors.any?

      report.assign_attributes(counter_notice_body: body, counter_notice_received_at: received_at)
      report.receive_counter_notice!
      Result.new(report:, errors: [])
    rescue StateMachines::InvalidTransition => e
      Result.new(report:, errors: [e.message])
    end

    # The forwarding time is written only once the mailer has taken the mail. Written before, a
    # failed enqueue would leave a record that says the seller was told when they were never told,
    # and the retry above would have nothing to detect.
    def deliver
      PiracyReportMailer.counter_notice_received(report.id).deliver_later
      report.update!(counter_notice_forwarded_at: Time.current)
      Result.new(report:, errors: [])
    rescue StandardError => e
      Result.new(report:, errors: ["The seller could not be told: #{e.message}"])
    end
end
