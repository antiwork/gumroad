# frozen_string_literal: true

class Admin::ScheduledPayoutPresenter
  attr_reader :scheduled_payout

  def initialize(scheduled_payout:)
    @scheduled_payout = scheduled_payout
  end

  def props
    {
      external_id: scheduled_payout.external_id,
      action: scheduled_payout.action,
      status: scheduled_payout.status,
      delay_days: scheduled_payout.delay_days,
      scheduled_at: scheduled_payout.scheduled_at,
      executed_at: scheduled_payout.executed_at,
      payout_amount_cents: scheduled_payout.payout_amount_cents,
      created_at: scheduled_payout.created_at,
      user: {
        external_id: scheduled_payout.user.external_id,
        email: scheduled_payout.user.form_email,
        name: scheduled_payout.user.name
      },
      created_by: scheduled_payout.created_by ? {
        name: scheduled_payout.created_by.name
      } : nil
    }
  end
end
