# frozen_string_literal: true

class HandleNewBankAccountWorker
  include Sidekiq::Job
  sidekiq_options retry: 10, queue: :default

  # Only the worker raises on unknown sync failures; inline callers (webhook path) ignore the
  # return so an unclassified Stripe error can't trigger a retry of the whole webhook event.
  # Recording a single admin breadcrumb is deferred to `sidekiq_retries_exhausted` so a transient
  # Stripe outage doesn't paper the user's admin profile with one note per retry.
  sidekiq_retries_exhausted do |msg, _exception|
    bank_account_id = msg["args"].first
    bank_account = BankAccount.find_by(id: bank_account_id)
    next unless bank_account

    # The Stripe exception class/message isn't preserved through Sidekiq's retry mechanism
    # (the worker re-raises a generic RuntimeError), so callers needing root cause look in
    # Sentry — the sync method called ErrorNotifier.notify on every failed attempt.
    content = "Stripe bank sync failed and exhausted Sidekiq retries for bank_account_id=" \
              "#{bank_account_id}. See Sentry for the underlying Stripe error."
    begin
      bank_account.user.add_payout_note(content:)
    rescue => e
      Rails.logger.error "Failed to record payout-note breadcrumb for user #{bank_account.user_id}: #{e.class}: #{e.message}"
      ErrorNotifier.notify(e)
    end
  end

  def perform(bank_account_id)
    bank_account = BankAccount.find(bank_account_id)
    result = StripeMerchantAccountManager.handle_new_bank_account(bank_account)
    raise "Stripe bank sync failed with unknown error for bank_account=#{bank_account_id}" if result == :stripe_unknown_error
  end
end
