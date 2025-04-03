# frozen_string_literal: true

class Admin::Charges::ChargePolicy < ApplicationPolicy
  def sync_status_with_charge_processor?
    record.purchases.where(purchase_state: %w(in_progress failed)).exists?
  end

  def refund?
    record.successful_purchases.non_free.not_fully_refunded.exists?
  end

  def refund_for_fraud?
    refund?
  end
end
