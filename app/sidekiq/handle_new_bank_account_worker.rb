# frozen_string_literal: true

class HandleNewBankAccountWorker
  include Sidekiq::Job
  sidekiq_options retry: 10, queue: :default

  def perform(bank_account_id)
    bank_account = BankAccount.find(bank_account_id)
    StripeMerchantAccountManager.handle_new_bank_account(bank_account)
  end
end
