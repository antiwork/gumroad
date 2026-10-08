# frozen_string_literal: true

# Records how a sent notice ended, and tells the seller.
class PiracyReports::ResolveService
  MAX_REASON_LENGTH = 2000

  Result = Struct.new(:report, :errors, keyword_init: true) do
    def success?
      errors.empty?
    end
  end

  def initialize(report:, outcome:, reason: nil)
    @report = report
    @outcome = outcome.to_s
    @reason = reason.to_s.strip.presence
  end

  # outcome_notified_at claims the seller email under the lock, so overlapping requests cannot both
  # send it. A failed queue releases the claim, so a retry with the same outcome finishes the email.
  # The outcome travels with the job: a counter-notice can reopen the report before the job runs.
  def call
    result = report.with_lock { record }
    return result unless result.success?

    begin
      PiracyReportMailer.resolved(report.id, outcome).deliver_later
    rescue StandardError
      report.update!(outcome_notified_at: nil)
      raise
    end
    result
  end

  private
    attr_reader :report, :outcome, :reason

    def record
      if unnotified_retry?
        report.update!(outcome_notified_at: Time.current)
        return Result.new(report:, errors: [])
      end
      return Result.new(report:, errors: ["The report already has an outcome"]) if report.resolved?
      return Result.new(report:, errors: ["The report has no notice out with a host"]) unless report.can_resolve?

      errors = []
      errors << "outcome must be one of #{PiracyReport::OUTCOMES.join(", ")}" unless PiracyReport::OUTCOMES.include?(outcome)
      errors << "a withdrawn report needs a reason" if outcome == "withdrawn" && reason.blank?
      errors << "restored needs a recorded counter-notice" if outcome == "restored" && !report.counter_noticed?
      errors << "reason is too long" if reason.to_s.length > MAX_REASON_LENGTH
      return Result.new(report:, errors:) if errors.any?

      report.assign_attributes(outcome:, outcome_reason: reason, resolved_at: Time.current, outcome_notified_at: Time.current)
      report.resolve!
      Result.new(report:, errors: [])
    end

    def unnotified_retry?
      report.resolved? && report.outcome == outcome && report.outcome_notified_at.nil?
    end
end
