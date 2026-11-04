# frozen_string_literal: true

# Taiwan holder names saved before the Stripe sync existed never reached Stripe.
# The worker resubmits the bank only when Stripe's stored name differs from ours.
module Onetime
  class SyncTaiwanBankHolderNamesToStripe
    def self.process
      new.process
    end

    def process
      TaiwanBankAccount.alive.includes(:user).find_each do |bank_account|
        user = bank_account.user
        next unless user&.active_bank_account == bank_account

        stripped_name = bank_account.account_holder_full_name.strip
        bank_account.update_column(:account_holder_full_name, stripped_name) if stripped_name != bank_account.account_holder_full_name
        next unless StripeMerchantAccountManager.account_holder_name_synced_to_stripe?(user, bank_account)

        HandleNewBankAccountWorker.perform_async(bank_account.id)
        puts "Enqueued sync for TaiwanBankAccount #{bank_account.id}"
      end
    end
  end
end
