# frozen_string_literal: true

class HandleNewBankAccountWorker
  include Sidekiq::Job
  sidekiq_options retry: 10, queue: :default

  # Inline callers (webhook path) ignore the return to avoid retry storms on unrelated resources.
  # The worker is the single place where :stripe_unknown_error becomes a Sidekiq retry.
  def perform(bank_account_id)
    bank_account = BankAccount.find(bank_account_id)
    result = StripeMerchantAccountManager.handle_new_bank_account(bank_account)
    raise "Stripe bank sync failed with unknown error for bank_account=#{bank_account_id}" if result == :stripe_unknown_error
  end
end
