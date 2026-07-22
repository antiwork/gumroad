# frozen_string_literal: true

class Settings::Payments::UserPolicy < ApplicationPolicy
  def show?
    user.role_admin_for?(seller)
  end

  # Payout configuration (bank account, PayPal, payout schedule, compliance
  # info, etc.) can be managed by the account owner and by team members with
  # the admin role. The `record == seller` guard ensures the record being
  # mutated is the seller account currently in context — it prevents a
  # request from targeting a different user than the one the policy was
  # authorized for.
  def update?
    user.role_admin_for?(seller) && record == seller
  end

  def set_country?
    update?
  end

  def opt_in_to_au_backtax_collection?
    update?
  end

  # Identity verification submits the account owner's personal identity
  # documents (KYC). A team admin cannot legitimately verify someone else's
  # identity, so these two actions remain owner-only.
  def verify_document?
    owner_only_update?
  end

  def verify_identity?
    owner_only_update?
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

  private
    def owner_only_update?
      user.role_owner_for?(seller) && record == seller
    end
end
