# frozen_string_literal: true

# Reports activity that landed on a Gumroad-managed Stripe account after a Stripe Connect link
# retired it (gumroad-private#3182).
#
# Retiring a managed account takes it out of payout preparation while the funds stay at Stripe, so
# anything that books to it afterwards cannot be paid out from it. StripeConnectAccountLinker refuses
# a replacement that still has unsettled obligations, but a check at the switch cannot see the future:
# a sale that picks the account while the link commits, a sale that settles later than the linker
# looks, a refund or a chargeback that arrives on the buyer's clock. This job is the net under that,
# and it is why the obligations check belongs at the switch (once per retirement, on the rare side)
# rather than on every charge: the residue above is not a race a per-charge read can order anyway.
#
# It runs at the settlement tail rather than immediately. One read of everything created at or after
# the retirement covers the race and the late settlement in the same pass, so an earlier run finds
# nothing this one would not.
#
# Reports only. Recovering a stranded balance needs a payout from the retired account, and moving
# money is a human decision.
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
    # A retired account that has come back is not stranded: it is a payout destination again.
    return if merchant_account.active?

    retired_at = Time.iso8601(retired_at_iso)
    landed = landed_since(merchant_account, retired_at)
    return if landed.empty?

    log_landed(merchant_account, retired_at, landed)
    InternalNotificationWorker.perform_async("payouts", "Activity on a retired Stripe account",
                                             message_for(merchant_account, retired_at, landed))
  end

  private
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
    def landed_since(merchant_account, retired_at)
      landed = []
      if merchant_account.user_id.present?
        collect(landed, "purchase",
                Purchase.where(seller_id: merchant_account.user_id, merchant_account_id: merchant_account.id), retired_at)
        collect(landed, "balance",
                Balance.where(user_id: merchant_account.user_id, merchant_account_id: merchant_account.id), retired_at)
      end
      collect(landed, "charge", Charge.where(merchant_account_id: merchant_account.id), retired_at)
      collect(landed, "balance_transaction", BalanceTransaction.where(merchant_account_id: merchant_account.id), retired_at)
      landed.sort_by { |row| row[:created_at] }
    end

    # At or after, not after: `deleted_at` is stored to the second, so a row created in the same second
    # as the retirement cannot be told apart from one created just before it. This is a report — a
    # borderline row named twice is better than one dropped.
    #
    # Stops reading once one row past the report cap is held: the count in the headline is then a
    # floor, and `message_for` says so rather than presenting it as the total.
    def collect(landed, kind, scope, retired_at)
      return if landed.size > MAX_REPORTED

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
