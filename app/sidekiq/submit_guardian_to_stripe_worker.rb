# frozen_string_literal: true

class SubmitGuardianToStripeWorker
  include Sidekiq::Worker

  def perform(user_id)
    user = User.find(user_id)
    user_compliance_info = user.alive_user_compliance_info

    return unless user_compliance_info&.user_under_18?
    return unless user_compliance_info.guardian_verification_required?

    merchant_account = user.merchant_accounts.stripe.alive.last
    return unless merchant_account&.charge_processor_merchant_id.present?

    begin
      # Get existing guardian person from Stripe
      stripe_persons = Stripe::Account.list_persons(merchant_account.charge_processor_merchant_id)["data"]
      guardian_person = stripe_persons.find { |person| person["relationship"]["representative"] == true && person["relationship"]["owner"] == false }

      guardian_params = StripeMerchantAccountManager.guardian_person_hash(user_compliance_info, GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
      guardian_params.deep_merge!(relationship: { representative: true, owner: false, title: "Legal Guardian" })

      if guardian_person
        # Update existing guardian person
        Stripe::Account.update_person(merchant_account.charge_processor_merchant_id, guardian_person["id"], guardian_params)
        Rails.logger.info "Updated guardian person for user #{user.id} in Stripe"
      else
        # Create new guardian person
        Stripe::Account.create_person(merchant_account.charge_processor_merchant_id, guardian_params)
        Rails.logger.info "Created guardian person for user #{user.id} in Stripe"
      end

    rescue => e
      Rails.logger.error "Failed to submit guardian information to Stripe for user #{user.id}: #{e.message}"
      # Update status to incomplete if Stripe submission fails
      user_compliance_info.update_column(:guardian_verification_status, "incomplete")
      raise e
    end
  end
end
