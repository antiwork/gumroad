# frozen_string_literal: true

class MerchantRegistrationMailer < ApplicationMailer
  default from: ADMIN_EMAIL

  layout "layouts/email"

  def account_deauthorized_to_user(user_id, charge_processor_id)
    @user = User.find(user_id)
    @charge_processor_display_name = ChargeProcessor::DISPLAY_NAME_MAP[charge_processor_id]
    subject = "Payments account disconnected - #{@user.external_id}"
    mail(subject:, from: NOREPLY_EMAIL_WITH_NAME, to: @user.email)
  end

  def account_needs_registration_to_user(affiliate_id, charge_processor_id)
    @affiliate = Affiliate.find(affiliate_id)
    @user = @affiliate.affiliate_user
    @charge_processor_id = charge_processor_id
    subject = "#{@charge_processor_id.capitalize} account required"
    mail(subject:, from: NOREPLY_EMAIL_WITH_NAME, to: @user.email)
  end

  def confirm_email_on_paypal(user_id, email)
    @user = User.find(user_id)
    @subject = "Please confirm your email address with PayPal"
    @body = "You need to confirm the email address (#{email}) attached to your PayPal account before you can start using it with Gumroad."
    mail(subject: @subject, from: NOREPLY_EMAIL_WITH_NAME, to: @user.email)
  end

  def paypal_account_updated(user_id)
    @user = User.find(user_id)
    @subject = "Your Paypal Connect account was updated."
    @body = "Your Paypal Connect account was updated.\n\nPlease verify the new payout address to confirm the changes for your <a href=\"#{settings_payments_url}\">payment settings</a>"
    mail(subject: @subject, from: NOREPLY_EMAIL_WITH_NAME, to: @user.email)
  end

  def stripe_charges_disabled(user_id)
    user = User.find(user_id)
    mail(subject: "Action required: Your sales have stopped", from: NOREPLY_EMAIL_WITH_NAME, to: user.email)
  end

  def stripe_payouts_disabled(user_id)
    user = User.find(user_id)
    mail(subject: "Action required: Your payouts are paused", from: NOREPLY_EMAIL_WITH_NAME, to: user.email)
  end
end
