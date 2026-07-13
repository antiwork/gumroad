# frozen_string_literal: true

class UpdateUserCountry
  # Raised when the user has a payout that is still in flight. Changing country deletes the
  # user's current Stripe account, so if a payout that is still processing later fails or is
  # returned by the bank, the money is re-credited to an account nobody watches anymore and
  # the funds strand there. Callers should ask the user to wait until the payout settles.
  class PayoutInProcessingError < StandardError; end

  attr_reader :new_country_code, :user

  def initialize(new_country_code:, user:)
    @old_country_code = user.alive_user_compliance_info.legal_entity_country_code
    @new_country_code = new_country_code
    @user = user
  end

  def process
    raise PayoutInProcessingError if @user.payments.processing.exists?

    keep_payment_address = !@user.native_payouts_supported? && !@user.native_payouts_supported?(country_code: @new_country_code)
    @user.update!(payment_address: "") unless keep_payment_address

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
