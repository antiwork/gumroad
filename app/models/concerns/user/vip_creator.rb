# frozen_string_literal: true

module User::VipCreator
  extend ActiveSupport::Concern

  VIP_GROSS_PAID_PAYOUTS_THRESHOLD_CENTS = 5_000_00

  def vip_creator?
    gross_paid_payouts_cents > VIP_GROSS_PAID_PAYOUTS_THRESHOLD_CENTS
  end

  private
    def gross_paid_payouts_cents
      payments.completed.sum(:amount_cents)
    end
end
