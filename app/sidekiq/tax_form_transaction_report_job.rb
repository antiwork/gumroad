# frozen_string_literal: true

# Builds the 1099-K transaction report for a creator and emails it to them.
# Runs in the background because the report pages through a full year of
# Stripe balance transactions, which is too slow for a web request. The
# uniqueness lock means repeated clicks on "Request report" collapse into one
# job (and one email) instead of one per click.
class TaxFormTransactionReportJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3, lock: :until_executed

  # The creator was told "you'll receive an email shortly" when they clicked
  # the button, so a job that gives up after all retries should not vanish
  # silently — surface it so someone can follow up.
  sidekiq_retries_exhausted do |job, exception|
    ErrorNotifier.notify(exception, context: { user_id: job["args"].first, year: job["args"].second })
  end

  def perform(user_id, year)
    user = User.find(user_id)

    tax_form = user.user_tax_forms.for_year(year).where(tax_form_type: "us_1099_k").first
    return if tax_form.blank?

    stripe_account_id = tax_form.stripe_account_id || user.stripe_account&.charge_processor_merchant_id
    return if stripe_account_id.blank?
    # Only build the report against a Stripe account that is still connected
    # and belongs to this creator. Guards against stale account ids on old
    # tax form records and accounts that have since been disconnected.
    return unless user.merchant_accounts.alive.charge_processor_alive.stripe.exists?(charge_processor_merchant_id: stripe_account_id)

    tempfile = Exports::TaxSummary::TransactionReport.new(user:, year:, stripe_account_id:).perform
    ContactingCreatorMailer.tax_form_transaction_report(user.id, year, tempfile).deliver_now
  ensure
    tempfile&.close
  end
end
