# frozen_string_literal: true

module User::LowBalanceFraudCheck
  extend ActiveSupport::Concern

  LOW_BALANCE_THRESHOLD = -100_00 # USD -100
  private_constant :LOW_BALANCE_THRESHOLD

  LOW_BALANCE_PROBATION_WAIT_TIME = 2.months
  private_constant :LOW_BALANCE_PROBATION_WAIT_TIME

  LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME = LowBalanceProbationRecovery::PROBATION_AUTHOR_NAME
  private_constant :LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME

  def enable_refunds!
    self.refunds_disabled = false
    save!
  end

  def disable_refunds!
    self.refunds_disabled = true
    save!
  end

  def check_for_low_balance_and_probate(refunded_or_disputed_purchase_id)
    return if unpaid_balance_cents > LOW_BALANCE_THRESHOLD

    AdminMailer.low_balance_notify(id, refunded_or_disputed_purchase_id).deliver_later

    disable_refunds_and_put_on_probation! unless recently_probated_for_low_balance? || suspended?
  end

  # Ends this account's LowBalanceFraudCheck probation once the balance has recovered. The checks
  # here only skip on this possibly stale copy; LowBalanceProbationRecovery decides under the row locks.
  def check_for_high_balance_and_remove_low_balance_probation!
    return unless on_probation?
    return unless unpaid_balance_cents >= LowBalanceProbationRecovery::RECOVERY_THRESHOLD_CENTS

    LowBalanceProbationRecovery.new(self).recover_automatically!
  end

  private
    def disable_refunds_and_put_on_probation!
      # Both writes have to land together or neither does. `disable_refunds!` saves
      # immediately, while the probation transition can be refused after the fact by
      # User::Risk#refuse_unauthorized_suspension_clear when the row turns out to be
      # suspended (this lane decides whether to act by reading `suspended?` off an
      # in-memory copy, so a suspension can land in between). Without the transaction
      # the refusal would leave the account with refunds disabled by a workflow that
      # is explicitly meant to skip suspended accounts, blocking refunds nobody
      # decided to block.
      transaction do
        disable_refunds!

        content = "Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of suspicious refund activity"
        self.put_on_probation(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME, content:)
      end
    rescue User::Risk::SuspensionClearNotAuthorizedError
      # The row was suspended by someone else while this check was in flight. That
      # decision outranks a low-balance probation, and the transaction above has
      # already rolled the refund flag back, so there is nothing left to do. Reload
      # so the caller's copy stops disagreeing with the row.
      reload
    end

    def recently_probated_for_low_balance?
      comments.with_type_on_probation
              .where(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME)
              .where("created_at > ?", LOW_BALANCE_PROBATION_WAIT_TIME.ago)
              .exists?
    end
end
