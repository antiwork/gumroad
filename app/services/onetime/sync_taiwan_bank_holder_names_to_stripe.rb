# frozen_string_literal: true

# Taiwan holder names saved before the Stripe sync existed never reached Stripe.
# The worker resubmits the bank only when Stripe's stored name differs from ours.
module Onetime
  class SyncTaiwanBankHolderNamesToStripe
    def self.process
      new.process
    end

    def process
      # Only banks Stripe already accepted, so a bank it rejected before is not resent. If Stripe rejects
      # the newly sent name, the seller gets the usual email, because their wires need a name the bank accepts.
      TaiwanBankAccount.alive.where.not(stripe_bank_account_id: nil).includes(:user).find_each do |bank_account|
        user = bank_account.user
        next unless user&.account_active? && user.active_bank_account == bank_account

        normalize_holder_name!(bank_account)
        next if bank_account.account_holder_full_name.blank?
        next unless StripeMerchantAccountManager.account_holder_name_synced_to_stripe?(user, bank_account)

        HandleNewBankAccountWorker.perform_async(bank_account.id)
        puts "Enqueued sync for TaiwanBankAccount #{bank_account.id}"
      end
    end

    private
      # Same normalization as the model's stripped_fields, which only runs on validation. The row lock
      # reloads under it, so a name the seller saves while this walks the table is never overwritten.
      def normalize_holder_name!(bank_account)
        bank_account.with_lock do
          StrippedFields::StrippedField.before_validation(
            bank_account, :account_holder_full_name, remove_duplicate_spaces: false, transform: nil, nilify_blanks: false
          )
          bank_account.update_column(:account_holder_full_name, bank_account.account_holder_full_name) if bank_account.account_holder_full_name_changed?
        end
      end
  end
end
