# frozen_string_literal: true

class Settings::Payments::UserPolicy < ApplicationPolicy
  def show?
    user.role_admin_for?(seller)
  end

  def update?
    user.role_owner_for?(seller) && record == seller
  end

  def set_country?
    update?
  end

  def opt_in_to_au_backtax_collection?
    update?
  end

  def verify_document?
    update?
  end

  def verify_identity?
    update?
  end

  def paypal_connect?
    update?
  end

  def stripe_connect?
    update?
  end

  def remove_credit_card?
    update?
  end

  def remediation?
    update?
  end

  def verify_stripe_remediation?
    update?
  end
end
