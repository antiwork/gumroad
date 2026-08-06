# frozen_string_literal: true

class ScheduleWorkflowInstallmentJob
  class RuleNotCommittedError < StandardError; end

  include Sidekiq::Job
  sidekiq_options retry: 10, queue: :low

  def perform(installment_id, rule_version, old_delayed_delivery_time, cutoff_reference_time)
    installment = Installment.find_by(id: installment_id)
    raise RuleNotCommittedError if installment.nil? || installment.installment_rule.nil?

    current_version = installment.installment_rule.version
    raise RuleNotCommittedError if current_version < rule_version

    # An older rule can own a wider recipient window. Preserve that window when a newer
    # rule commits first; SentPostEmail's unique key prevents duplicate delivery.
    installment.workflow.schedule_installment(
      installment,
      old_delayed_delivery_time:,
      cutoff_reference_time: Time.zone.iso8601(cutoff_reference_time),
      reschedule_on_stale: true
    )
  end
end
