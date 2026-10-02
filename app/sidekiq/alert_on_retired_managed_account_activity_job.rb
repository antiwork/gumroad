# frozen_string_literal: true

# Reports activity that landed on a Gumroad-managed Stripe account after a Stripe Connect link
# retired it. The check at the switch cannot see what lands later, so this runs at the settlement
# tail: one read of everything created at or after the retirement covers the late settlement and the
# race in the same pass.
#
# Reports only. Recovering a stranded balance needs a payout from the retired account.
class AlertOnRetiredManagedAccountActivityJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  # How long the linker waits before this runs. Payouts holds a sale at least this long before it can
  # pay it, so this is the settlement tail: everything a retired account can still receive from a sale
  # that was in flight when it was retired has landed by here.
  SETTLEMENT_TAIL = 3.days

  # Report at most this many landed rows. The alert exists to be read.
  MAX_REPORTED = 25

  def perform(merchant_account_id, retired_at_iso)
    merchant_account = MerchantAccount.find_by(id: merchant_account_id)
    return if merchant_account.nil?

    # Locked and inside one transaction: the marker read and its clear cannot be split by another
    # copy of the check, and a run that dies mid-report rolls the clear back with it.
    merchant_account.with_lock { report_landed_activity(merchant_account, retired_at_iso) }
  end

  private
    # The marker is the claim on the check, so the sweep's copy — dispatched for a scheduled copy
    # that is only delayed — finds it cleared instead of reporting the same activity again.
    def report_landed_activity(merchant_account, retired_at_iso)
      # A retired account that has come back is not stranded: it is a payout destination again, and
      # whatever retirement left the marker is moot.
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

      # Only the marker this check was dispatched for is spent here. A seller who reconnects inside
      # the tail leaves a marker for the later retirement, and that retirement's own check is the one
      # that reports from its `deleted_at` — clearing it here would skip it.
      clear_pending_marker(merchant_account) if marker == retired_at_iso
    end

    def clear_pending_marker(merchant_account)
      return if merchant_account.retired_activity_check_pending_at.blank?

      merchant_account.update!(retired_activity_check_pending_at: nil)
    end

    # Every leg is index-backed. `merchant_account_id` leads the index on charges and on balance
    # transactions. Balances has no index on it alone — its indexes lead on `state` or `user_id` — so
    # it is scoped by the account's owner too, which is what `index_on_user_merchant_account_date`
    # leads on. Purchases has no `merchant_account_id` index either, so it is scoped by the owner.
    # Both of those legs are inside the owner guard: a retired managed account always has one (the
    # linker only retires the account of the owner who is linking), and an ownerless account has no
    # balances or sales to report.
    #
    # Balance transactions are read in their own right rather than only through balances: a late
    # refund or chargeback adds one to a balance that already exists and inserts no new balance row,
    # so a scan of balances alone would miss it.
    #
    # The money-event legs are collected first, so a burst of purchases or balances cannot fill the
    # report cap and leave that refund's balance transaction out of the list.
    def landed_since(merchant_account, retired_at)
      landed = []
      collect(landed, "balance_transaction", BalanceTransaction.where(merchant_account_id: merchant_account.id), retired_at)
      collect(landed, "charge", Charge.where(merchant_account_id: merchant_account.id), retired_at)
      if merchant_account.user_id.present?
        collect(landed, "purchase",
                Purchase.where(seller_id: merchant_account.user_id, merchant_account_id: merchant_account.id), retired_at)
        collect(landed, "balance",
                Balance.where(user_id: merchant_account.user_id, merchant_account_id: merchant_account.id), retired_at)
      end
      # Grouped by leg rather than re-sorted: the report is truncated to the first rows, and the money
      # events above must not be the ones dropped.
      landed
    end

    # At or after, not after: `deleted_at` is stored to the second, so a row created in the same second
    # as the retirement cannot be told apart from one created just before it. This is a report — a
    # borderline row named twice is better than one dropped.
    #
    # Stops reading a leg once one row past the report cap is held. Bounded per leg rather than by one
    # running total, so no leg is skipped because an earlier one filled the cap: the count in the
    # headline is a floor over the legs that were read, and `message_for` says so.
    def collect(landed, kind, scope, retired_at)
      scope.where("created_at >= ?", retired_at).order(:created_at).limit(MAX_REPORTED + 1).each do |record|
        landed << { kind:, record:, created_at: record.created_at }
      end
    end

    # The machine-readable half of the finding: a search for this account in the logs answers what
    # landed and when without parsing the alert text.
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
