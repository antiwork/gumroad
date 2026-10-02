# frozen_string_literal: true

# Reports activity that landed on a Gumroad-managed Stripe account after a Stripe Connect link retired
# it: one read at the settlement tail, by `created_at`, covers the late settlement and the race in the
# same pass. Reports only — recovering a stranded balance is a human decision.
class AlertOnRetiredManagedAccountActivityJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  # SyncStuckPurchasesJob resolves an in_progress sale for 3 days, so most sales in flight at retirement
  # have landed by then. UnstickStuckInProgressPurchasesJob can still resolve one up to 90 days old, so
  # the report covers what is present at this tail, not every late settlement.
  SETTLEMENT_TAIL = 3.days

  # Report at most this many landed rows per leg. The alert exists to be read.
  MAX_REPORTED = 25

  def perform(merchant_account_id, retired_at_iso)
    merchant_account = MerchantAccount.find_by(id: merchant_account_id)
    return if merchant_account.nil?

    # Locked and inside one transaction: the marker read and its clear cannot be split by another copy
    # of the check, and a run that dies mid-report rolls the clear back with it.
    merchant_account.with_lock { report_landed_activity(merchant_account, retired_at_iso) }
  end

  private
    # The marker is the claim on the check, so the sweep's copy — dispatched for a scheduled copy that
    # is only delayed — finds it cleared instead of reporting the same activity again.
    def report_landed_activity(merchant_account, retired_at_iso)
      # A retired account that has come back is a payout destination again, so whatever left the marker
      # is moot.
      return clear_pending_marker(merchant_account) if merchant_account.active?

      marker = merchant_account.retired_activity_check_pending_at
      return if marker.blank? # Already reported.

      retired_at = Time.iso8601(retired_at_iso)
      landed = landed_since(merchant_account, retired_at)
      if landed.present?
        log_landed(merchant_account, retired_at, landed)
        InternalNotificationWorker.perform_async("payouts", "Activity on a retired Stripe account",
                                                 message_for(merchant_account, retired_at, landed))
      end

      # Only the marker this check was dispatched for is spent here. A seller who reconnects inside the
      # tail leaves a marker for the later retirement, and that retirement's own check is the one that
      # reports from its `deleted_at` — clearing it here would skip it.
      clear_pending_marker(merchant_account) if marker == retired_at_iso
    end

    def clear_pending_marker(merchant_account)
      return if merchant_account.retired_activity_check_pending_at.blank?

      merchant_account.update!(retired_activity_check_pending_at: nil)
    end

    # Charges and balance transactions are read on `merchant_account_id`, which leads their index.
    # Balances has no index on it alone, so that leg carries the owner too.
    #
    # Balance transactions are read in their own right — a late refund or chargeback adds one to a
    # balance that already exists and inserts no new balance row — and they are read first, so a burst
    # of balances cannot fill the report cap and drop them from the list.
    #
    # Purchases are not read: a sale that moved money left a charge and a balance transaction, and the
    # `seller_id` walk purchase rows would need is the expensive one on a large seller.
    def landed_since(merchant_account, retired_at)
      landed = []
      collect(landed, "balance_transaction", BalanceTransaction.where(merchant_account_id: merchant_account.id), retired_at)
      collect(landed, "charge", Charge.where(merchant_account_id: merchant_account.id), retired_at)
      if merchant_account.user_id.present?
        collect(landed, "balance",
                Balance.where(user_id: merchant_account.user_id, merchant_account_id: merchant_account.id), retired_at)
      end
      landed
    end

    # At or after, not after: `deleted_at` is stored to the second, so a row in the same second as the
    # retirement cannot be told apart from one just before it — a report may name a borderline row
    # twice, but must not drop one.
    #
    # Bounded per leg rather than by one running total, so no leg is skipped because an earlier one
    # filled the cap; the headline count is then a floor, and `message_for` says so.
    def collect(landed, kind, scope, retired_at)
      scope.where("created_at >= ?", retired_at).order(:created_at).limit(MAX_REPORTED + 1).each do |record|
        landed << { kind:, record:, created_at: record.created_at }
      end
    end

    # Searchable by account id without parsing the alert text.
    def log_landed(merchant_account, retired_at, landed)
      Rails.logger.info(
        "retired_managed_account_activity " \
        "merchant_account_id=#{merchant_account.id} " \
        "charge_processor_merchant_id=#{merchant_account.charge_processor_merchant_id} " \
        "seller_id=#{merchant_account.user_id} " \
        "retired_at=#{retired_at.utc.iso8601} " \
        "landed_count=#{landed.size} " \
        "kinds=#{landed.group_by { |row| row[:kind] }.transform_values(&:size).sort.to_h}"
      )
    end

    def message_for(merchant_account, retired_at, landed)
      lines = landed.first(MAX_REPORTED).map { |row| line_for(row) }
      truncated = landed.size > lines.size

      [
        "#{truncated ? "At least " : ""}#{landed.size} row#{"s" if landed.size != 1} landed on " \
          "Gumroad-managed Stripe account #{merchant_account.charge_processor_merchant_id} " \
          "(merchant account #{merchant_account.id}, seller #{merchant_account.user_id}) after a " \
          "Stripe Connect link retired it at #{retired_at.utc.iso8601}.",
        "",
        *lines,
        (truncated ? "…and more, past the #{MAX_REPORTED} this report lists." : nil),
        "",
        "Retiring the account removed it as a payout destination, so a balance that booked to it " \
          "afterwards cannot be paid out from it. These rows are a sale that was in flight when the " \
          "account was retired or that settled late, or a refund or chargeback that arrived " \
          "afterwards — none of which a check at the switch can order. Check the account's Stripe " \
          "balance before deciding: recovering it needs a payout from the retired account, which is " \
          "a human decision. See gumroad-private#3182.",
      ].compact.join("\n")
    end

    def line_for(row)
      record = row[:record]
      position = "#{row[:kind]} #{record.id} at #{row[:created_at].utc.iso8601}"
      return "• #{position}" unless row[:kind] == "balance"

      "• #{position} — #{record.state}, #{record.amount_cents} #{record.currency} cents"
    end
end
