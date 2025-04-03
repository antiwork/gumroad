# frozen_string_literal: true

# This script deactivates affiliates for Stripe Connect accounts in Brazil
module Onetime::DeactivateAffiliatesForStripeConnectBrazil
  extend self

  def process
    eligible_merchant_accounts.find_each do |merchant_account|
      process_merchant_account!(merchant_account)
    end
  end

  private
    def eligible_merchant_accounts
      MerchantAccount.includes(user: :merchant_accounts)
        .alive
        .charge_processor_alive
        .stripe_connect
        .where(country: Compliance::Countries::BRA.alpha2)
    end

    def process_merchant_account!(merchant_account)
      seller = merchant_account.user
      if seller.merchant_account(StripeChargeProcessor.charge_processor_id).is_a_brazilian_stripe_connect_account?
        Rails.logger.info("Skipping seller #{seller.id} because their merchant account is not a Stripe Connect account from Brazil")
        return
      end

      Rails.logger.info("SELLER: #{seller.id}")

      ActiveRecord::Base.transaction do
        # disable global affiliates
        seller.update!(disable_global_affiliate: true)

        if Affiliate.alive.where(seller_id: seller.id).present?
          # email seller
          subject = "Gumroad affiliate and collaborator programs are no longer available in Brazil"
          body = <<~BODY
            Hi there,

            You are getting this email because you have affiliates or collaborators and are based out of Brazil.

            Unfortunately, recent changes made by Stripe have required us to suspend our affiliate and collaborator programs for Brazilian creators. Going forward, your affiliates and collaborators will be disabled and will no longer receive payments for purchases made through them, including for pre-existing membership subscriptions. They will be separately notified of this change.

            We apologize for the inconvenience.

            Best,
            Sahil and the Gumroad Team.
          BODY
          OneOffMailer.email(user_id: seller.id, subject:, body:)

          # email & deactivate direct affiliates & collaborators
          Affiliate.alive.where(seller_id: seller.id).find_each do |affiliate|
            Rails.logger.info("- affiliate: #{affiliate.id}")
            affiliate_type = affiliate.collaborator? ? "collaborator" : "affiliate"
            subject = "Gumroad #{affiliate_type} program is no longer available in Brazil"
            body = <<~BODY
              Hi there,

              You are getting this email because you are #{affiliate.collaborator? ? "a collaborator" : "an affiliate"} for a Gumroad creator based out of Brazil.

              Unfortunately, recent changes made by Stripe have required us to suspend our #{affiliate_type} program for Brazilian creators. Going forward, you will no longer receive affiliate payments for purchases made through these creators, including for pre-existing membership subscriptions. Non-Brazil-based creators are not affected by this change, and you will continue to receive #{affiliate_type} payments as usual for those creators.

              We apologize for the inconvenience.

              Best,
              Sahil and the Gumroad Team.
            BODY
            OneOffMailer.email(user_id: affiliate.affiliate_user_id, subject:, body:)
            affiliate.mark_deleted!
          end
        end
      end
    end
end
