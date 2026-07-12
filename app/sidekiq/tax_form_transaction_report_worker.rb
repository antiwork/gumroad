# frozen_string_literal: true

# Builds the 1099-K transaction report for a creator and emails it to them.
# Runs in the background because the report can page through a full year of
# Stripe balance transactions, which is too slow for a web request.
class TaxFormTransactionReportWorker
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3

  def perform(user_id, year)
    user = User.find(user_id)

    tax_form = user.user_tax_forms.for_year(year).where(tax_form_type: "us_1099_k").first
    return if tax_form.blank?

    stripe_account_id = tax_form.stripe_account_id || user.stripe_account&.charge_processor_merchant_id
    return if stripe_account_id.blank?
    # Only build the report against a Stripe account that still belongs to
    # this creator. Guards against stale account ids on old tax form records.
    return unless user.merchant_accounts.stripe.exists?(charge_processor_merchant_id: stripe_account_id)

    tempfile = Exports::TaxSummary::TransactionReport.new(user:, year:, stripe_account_id:).perform
    ContactingCreatorMailer.tax_form_transaction_report(user.id, year, tempfile).deliver_now
  ensure
    tempfile&.close
  end
end
