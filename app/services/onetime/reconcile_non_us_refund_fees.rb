# frozen_string_literal: true

class Onetime::ReconcileNonUsRefundFees
  def self.process(refund_ids:, dry_run: true)
    refunds = Refund.where(id: refund_ids).order(:id).to_a
    raise ArgumentError, "Refund IDs do not match existing refunds" unless refunds.map(&:id).sort == refund_ids.uniq.sort

    rows = refunds.map do |refund|
      credit = Credit.find_by(fee_retention_refund: refund, failed_refund_id: nil)
      account = credit&.merchant_account
      eligible = refund.fee_retention_pending == true && credit&.amount_cents&.negative? &&
        account&.holder_of_funds == HolderOfFunds::STRIPE && account.country.present? &&
        account.country != Compliance::Countries::USA.alpha2

      recovery_error = nil
      begin
        # Call directly so capped rows can reconcile without resetting their attempt history.
        refund.recover_pending_fee_retention! if eligible && !dry_run
      rescue StandardError => error
        recovery_error = { "class" => error.class.name, "message" => error.message }
      end
      refund.reload
      {
        refund_id: refund.id,
        eligible:,
        pending: refund.fee_retention_pending == true,
        fee_cents: credit&.amount_cents&.abs,
        written_off_cents: refund.fee_retention_written_off_cents.to_i,
        collected_transfer: refund.debited_stripe_transfer,
        error: recovery_error || refund.fee_retention_error
      }
    end
    {
      dry_run:,
      currency: Currency::USD,
      written_off_cents: rows.sum { |row| row[:written_off_cents] },
      pending_cents: rows.select { |row| row[:eligible] && row[:pending] }.sum { |row| row[:fee_cents] },
      rows:
    }
  end
end
