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

  def stripe_payouts_under_review(user_id)
    user = User.find(user_id)
    mail(subject: "Your payouts are temporarily paused", from: NOREPLY_EMAIL_WITH_NAME, to: user.email)
  end

  def stripe_account_rejected(user_id)
    @user = User.find(user_id)
    # Whether the remaining balance pays out automatically depends on whether
    # anything is pausing payouts: if Stripe disabled payouts on the rejected
    # account (or an admin/seller pause is active), the money can't move
    # automatically, so the email tells the seller to contact support instead
    # of promising a payout date.
    @payouts_blocked_by_stripe = @user.payouts_paused_internally? &&
      @user.payouts_paused_by_source == User::PAYOUT_PAUSE_SOURCE_STRIPE
    @payouts_blocked = @payouts_blocked_by_stripe || @user.payouts_paused?
    @balance_cents = @user.unpaid_balance_cents
    @formatted_balance = @user.formatted_dollar_amount(@balance_cents)
    # When the payout will run automatically, tell the seller the actual date
    # (their two questions are "how much" and "when"). The template falls back
    # to "your next scheduled payout" if the date can't be computed.
    @next_payout_date = @user.next_payout_date unless @payouts_blocked
    mail(subject: "You can no longer accept payments on Gumroad", from: NOREPLY_EMAIL_WITH_NAME, to: @user.email)
  end
end
