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

  # outcome_notified_at is set only once the seller email is queued, so a retry with the same
  # outcome after a failed queue sends the email instead of being refused.
  def call
    result = report.with_lock { record }
    return result unless result.success?

    PiracyReportMailer.resolved(report.id).deliver_later
    report.update!(outcome_notified_at: Time.current)
    result
  end

  private
    attr_reader :report, :outcome, :reason

    def record
      return Result.new(report:, errors: []) if unnotified_retry?
      return Result.new(report:, errors: ["The report already has an outcome"]) if report.resolved?
      return Result.new(report:, errors: ["The report has no notice out with a host"]) unless report.can_resolve?

      errors = []
      errors << "outcome must be one of #{PiracyReport::OUTCOMES.join(", ")}" unless PiracyReport::OUTCOMES.include?(outcome)
      errors << "a withdrawn report needs a reason" if outcome == "withdrawn" && reason.blank?
      errors << "restored needs a recorded counter-notice" if outcome == "restored" && !report.counter_noticed?
      errors << "reason is too long" if reason.to_s.length > MAX_REASON_LENGTH
      return Result.new(report:, errors:) if errors.any?

      report.assign_attributes(outcome:, outcome_reason: reason, resolved_at: Time.current, outcome_notified_at: nil)
      report.resolve!
      Result.new(report:, errors: [])
    end

    def unnotified_retry?
      report.resolved? && report.outcome == outcome && report.outcome_notified_at.nil?
    end
end
