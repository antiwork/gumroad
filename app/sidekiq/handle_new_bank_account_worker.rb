# frozen_string_literal: true

class HandleNewBankAccountWorker
  include Sidekiq::Job
  sidekiq_options retry: 10, queue: :default

  # Only the worker raises on unknown sync failures; inline callers (webhook path) ignore the
  # return so an unclassified Stripe error can't trigger a retry of the whole webhook event.
  def perform(bank_account_id)
    bank_account = BankAccount.find(bank_account_id)
    result = StripeMerchantAccountManager.handle_new_bank_account(bank_account)
    raise "Stripe bank sync failed with unknown error for bank_account=#{bank_account_id}" if result == :stripe_unknown_error
  end
end
