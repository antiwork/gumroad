# frozen_string_literal: true

FactoryBot.define do
  sequence :merchant_account_id do |n|
    n.to_s.rjust(9, "0")
  end

  factory :merchant_account, class: MerchantAccount do
    user
    charge_processor_id { StripeChargeProcessor.charge_processor_id }
    charge_processor_merchant_id { generate(:merchant_account_id) }
    charge_processor_alive_at { Time.current }
  end

  factory :merchant_account_paypal, class: MerchantAccount do
    user
    charge_processor_id { PaypalChargeProcessor.charge_processor_id }
    charge_processor_merchant_id { generate(:merchant_account_id) }
    charge_processor_alive_at { Time.current }
  end

  factory :merchant_account_stripe, class: MerchantAccount do
    user
    initialize_with do
      create(:tos_agreement, user:)
      create(:user_compliance_info, user:)
      merchant_account = StripeMerchantAccountManager.create_account(user, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
      StripeMerchantAccountHelper.upload_verification_document(merchant_account.charge_processor_merchant_id)
      StripeMerchantAccountHelper.ensure_charges_enabled(merchant_account.charge_processor_merchant_id)
      merchant_account
    end
  end

  factory :merchant_account_stripe_canada, class: MerchantAccount do
    user
    initialize_with do
      create(:tos_agreement, user:)
      create(:user_compliance_info_canada, user:)
      merchant_account = StripeMerchantAccountManager.create_account(user, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
      StripeMerchantAccountHelper.upload_verification_document(merchant_account.charge_processor_merchant_id)
      StripeMerchantAccountHelper.ensure_charges_enabled(merchant_account.charge_processor_merchant_id)
      merchant_account
    end
  end

  factory :merchant_account_stripe_korea, class: MerchantAccount do
    user
    initialize_with do
      create(:tos_agreement, user:)
      create(:user_compliance_info_korea, user:)
      merchant_account = StripeMerchantAccountManager.create_account(user, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
      StripeMerchantAccountHelper.upload_verification_document(merchant_account.charge_processor_merchant_id)
      StripeMerchantAccountHelper.ensure_charges_enabled(merchant_account.charge_processor_merchant_id)
      merchant_account
    end
  end

  factory :merchant_account_stripe_mexico, class: MerchantAccount do
    user
    initialize_with do
      create(:tos_agreement, user:)
      create(:user_compliance_info_mex_business, user:)
      merchant_account = StripeMerchantAccountManager.create_account(user, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
      StripeMerchantAccountHelper.upload_verification_document(merchant_account.charge_processor_merchant_id)
      StripeMerchantAccountHelper.ensure_charges_enabled(merchant_account.charge_processor_merchant_id)
      merchant_account
    end
  end

  factory :merchant_account_stripe_connect, class: MerchantAccount do
    user
    charge_processor_id { StripeChargeProcessor.charge_processor_id }
    charge_processor_merchant_id { "acct_1SOb0DEwFhlcVS6d" }
    charge_processor_alive_at { Time.current }
    json_data { { "meta" => { "stripe_connect" => "true" } } }
  end
end
