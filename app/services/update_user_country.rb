# frozen_string_literal: true

class UpdateUserCountry
  # Raised when the user has a payout that is still in flight. Changing country deletes the
  # user's current Stripe account, so if a payout that is still in flight later fails or is
  # returned by the bank, the money is re-credited to an account nobody watches anymore and
  # the funds strand there. Callers should ask the user to wait until the payout settles.
  class PayoutInProcessingError < StandardError; end

  # Payout states that mean money is still moving: the payout has been created or sent but has
  # not reached a settled outcome yet. "unclaimed" is PayPal-specific (the recipient hasn't
  # accepted the money), and "creating" is the brief window before the payout is submitted.
  # Completed payouts are not included: a completed Stripe payout can still be returned by the
  # bank later, but Gumroad pays out weekly, so blocking on recent completions would lock
  # nearly every active seller out of country changes. That residual case is handled by
  # alerting when a returned payout lands on a retired account.
  PAYOUT_IN_FLIGHT_STATES = %w[creating processing unclaimed]

  attr_reader :new_country_code, :user

  def initialize(new_country_code:, user:)
    @old_country_code = user.alive_user_compliance_info.legal_entity_country_code
    @new_country_code = new_country_code
    @user = user
  end

  def process
    raise PayoutInProcessingError if @user.payments.where(state: PAYOUT_IN_FLIGHT_STATES).exists?

    keep_payment_address = !@user.native_payouts_supported? && !@user.native_payouts_supported?(country_code: @new_country_code)
    # Dropping the address also drops the record of one we removed for a permanent PayPal refusal
    # (Payment#invalidate_paypal_payout_address). The seller is choosing a new payout setup here, so
    # the old rejection stops being their live situation — leaving it would resurrect it later.
    # Kept alongside the address in the other branch, on purpose: the marker only decides which
    # explanation the seller reads, never whether a payout is refused, and PayPal is still their
    # only rail here — saving an address clears it (UpdatePayoutMethod#process_payment_address_params).
    @user.update!(payment_address: "", invalidated_paypal_payout_address: nil) unless keep_payment_address

    @user.comments.create!(
      author_id: GUMROAD_ADMIN_ID,
      comment_type: Comment::COMMENT_TYPE_COUNTRY_CHANGED,
      content: "Country changed from #{@old_country_code} to #{@new_country_code}"
    )

    @user.forfeit_unpaid_balance!(:country_change)
    @user.stripe_account.try(:delete_charge_processor_account!)
    @user.active_bank_account.try(:mark_deleted!)
    @user.user_compliance_info_requests.requested.find_each(&:mark_provided!)

    @user.alive_user_compliance_info.mark_deleted(validate: false)
    @user.user_compliance_infos.build.tap do |new_user_compliance_info|
      new_user_compliance_info.country = Compliance::Countries.mapping[@new_country_code]
      new_user_compliance_info.json_data = {}
      new_user_compliance_info.save!
    end
  end
end
