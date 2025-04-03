# frozen_string_literal: true

class ServiceChargePolicy < ApplicationPolicy
  def create?
    user.role_owner_for?(seller)
  end

  def confirm?
    create?
  end

  def resend_receipt?
    create?
  end

  def send_invoice?
    create?
  end

  def generate_service_charge_invoice?
    create?
  end
end
