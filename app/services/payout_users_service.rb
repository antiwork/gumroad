# frozen_string_literal: true

class PayoutUsersService
  attr_reader :date, :processor_type, :user_ids, :payout_type

  def initialize(date_string:, processor_type:, user_ids:, payout_type: Payouts::PAYOUT_TYPE_STANDARD)
    @date = date_string
    @processor_type = processor_type
    @user_ids = Array.wrap(user_ids)
    @payout_type = payout_type
  end

  def process
    payments, cross_border_payments = create_payments

    PayoutProcessorType.get(processor_type).process_payments(payments) if payments.present?
    cross_border_payments.each do |payment|
      ProcessPaymentWorker.perform_in(25.hours, payment.id)
    end

    payments + cross_border_payments
  end

  def create_payments
    payments = []
    cross_border_payments = []

    user_ids.each do |user_id|
      user = User.find(user_id)
      payment, payment_errors = Payouts.create_payment(date, processor_type, user, payout_type:)

      if payment_errors.blank? && payment.present?
        # Money transferred to a cross-border-payouts Stripe Connect a/c becomes payable after 24 hours,
        # so schedule those payouts for 25 hours from now instead of processing them immediately.
        cross_border_payout = payment.processor == PayoutProcessorType::STRIPE &&
            !payment.user.merchant_accounts.find_by(charge_processor_merchant_id: payment.stripe_connect_account_id)&.is_a_stripe_connect_account? &&
            Country.new(user.alive_user_compliance_info.legal_entity_country_code).supports_stripe_cross_border_payouts?
        if cross_border_payout
          cross_border_payments << payment
        else
          payments << payment
        end
      else
        Rails.logger.info("Payouts: Create payment errors for user with id: #{user_id} #{payment_errors.inspect}")
      end
    rescue => e
      Rails.logger.error "Error in PayoutUsersService creating payment for user ID #{user_id} => #{e.class.name}: #{e.message}"
      Rails.logger.error "Error in PayoutUsersService creating payment for user ID #{user_id} => #{e.backtrace.join("\n")}"
      Bugsnag.notify(e)
      next
    end

    [payments, cross_border_payments]
  end
end
