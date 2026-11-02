# frozen_string_literal: true

# One send for an opened-no-click workflow, on the recipient's own clock.
#
# Separate from SendWorkflowInstallmentWorker because this wait is anchored to a recipient's open
# rather than to a purchase, a cancellation or a publish: the scan owns the timing, and the job
# re-reads the two things that can change between the scan and the send — a click, and the delivery
# rule.
class SendWorkflowEmailToOpenedNonClickerJob
  include Sidekiq::Job
  include DatabaseRoleRouting
  sidekiq_options retry: 5, queue: :low

  def perform(installment_id, rule_version, purchase_id, recipient_digest)
    with_primary_database do
      installment = Installment.find_by(id: installment_id)
      return if installment.nil?

      workflow = installment.workflow
      return if workflow.nil? || !workflow.opened_no_click_trigger?
      return if installment.seller&.suspended?
      # Follower and audience workflows of a retired newsletter stop here, including already
      # queued jobs; product and customer workflows of the same seller still send.
      return if (installment.follower_type? || installment.audience_type?) && FeatureAnnouncementNewsletterCutover.retired_for?(installment.seller_id)
      return unless workflow.alive? && installment.alive? && installment.published?

      rule = installment.installment_rule
      # A delay edit moves the clock for every open the scan has not sent yet: drop this send and
      # let the next scan queue it at the new time.
      return if rule.nil? || rule.version != rule_version

      installment.send_installment_from_workflow_for_opened_no_click(purchase_id, recipient_digest:)
    end
  end
end
