# frozen_string_literal: true

class ProcessEarlyFraudWarningJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  def perform(early_fraud_warning_id)
    early_fraud_warning = EarlyFraudWarning.find(early_fraud_warning_id)
    return if early_fraud_warning.resolved?

    early_fraud_warning.update_from_stripe!
    early_fraud_warning.reload

    if early_fraud_warning.actionable?
      process_actionable_record!(early_fraud_warning)
    else
      process_not_actionable_record!(early_fraud_warning)
    end
  end

  private
    def process_not_actionable_record!(early_fraud_warning)
      dispute = early_fraud_warning.dispute
      refund = early_fraud_warning.refund

      # It should not happen as an EFW is actionable if it has a dispute or refund associated
      raise "Cannot determine resolution" if dispute.blank? && refund.blank?

      resolution = \
        if dispute.present? && refund.present?
          if refund.created_at <= dispute.created_at
            EarlyFraudWarning::RESOLUTION_NOT_ACTIONABLE_REFUNDED
          else
            EarlyFraudWarning::RESOLUTION_NOT_ACTIONABLE_DISPUTED
          end
        elsif dispute.present?
          EarlyFraudWarning::RESOLUTION_NOT_ACTIONABLE_DISPUTED
        else
          EarlyFraudWarning::RESOLUTION_NOT_ACTIONABLE_REFUNDED
        end
      early_fraud_warning.update_as_resolved!(resolution:)
    end

    def process_actionable_record!(early_fraud_warning)
      early_fraud_warning.with_lock do
        if early_fraud_warning.chargeable_refundable_for_fraud?
          process_refundable_for_fraud!(early_fraud_warning)
        elsif early_fraud_warning.purchase_for_subscription_contactable?
          process_subscription_contactable!(early_fraud_warning)
        else
          process_resolved_ignored!(early_fraud_warning)
        end
      end
    end

    def process_refundable_for_fraud!(early_fraud_warning)
      early_fraud_warning.chargeable.refund_for_fraud_and_block_buyer!(GUMROAD_ADMIN_ID)
      early_fraud_warning.update_as_resolved!(
        resolution: EarlyFraudWarning::RESOLUTION_RESOLVED_REFUNDED_FOR_FRAUD
      )
    end

    def process_subscription_contactable!(early_fraud_warning)
      already_contacted_ids = early_fraud_warning.associated_early_fraud_warning_ids_for_subscription_contacted

      if already_contacted_ids.present?
        early_fraud_warning.update_as_resolved!(
          resolution: EarlyFraudWarning::RESOLUTION_RESOLVED_IGNORED,
          resolution_message: "Already contacted for EFW id #{already_contacted_ids.join(", ")}"
        )
      else
        CustomerLowPriorityMailer.subscription_early_fraud_warning_notification(
          early_fraud_warning.purchase_for_subscription.id
        ).deliver_later
        early_fraud_warning.update_as_resolved!(
          resolution: EarlyFraudWarning::RESOLUTION_RESOLVED_CUSTOMER_CONTACTED
        )
      end
    end

    def process_resolved_ignored!(early_fraud_warning)
      early_fraud_warning.update_as_resolved!(
        resolution: EarlyFraudWarning::RESOLUTION_RESOLVED_IGNORED
      )
    end
end
