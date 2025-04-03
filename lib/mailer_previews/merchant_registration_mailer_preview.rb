# frozen_string_literal: true

class MerchantRegistrationMailerPreview < ActionMailer::Preview
  def stripe_charges_disabled
    MerchantRegistrationMailer.stripe_charges_disabled(User.last&.id)
  end

  def account_needs_registration_to_user
    MerchantRegistrationMailer.account_needs_registration_to_user(Affiliate.last&.id, StripeChargeProcessor.charge_processor_id)
  end

  def stripe_payouts_disabled
    MerchantRegistrationMailer.stripe_payouts_disabled(User.last&.id)
  end
end
