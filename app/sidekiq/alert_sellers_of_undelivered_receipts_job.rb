# frozen_string_literal: true

# Nightly sweep telling sellers about buyers who paid and have no evidence of receiving their receipt
# (gumroad-private#1635). A receipt that is never delivery-confirmed sits in `email_infos` forever and
# reaches nobody: not the buyer, not the seller, not us.
#
# Measured on the production replica for a single settled day, excluding one suspended spam account
# that alone produced 143,746 of that day's 145,547 bounces: 231 purchases across 103 sellers where the
# receipt bounced and the buyer never opened their content, plus 112 across 54 sellers stuck at `sent`.
# Most sellers have exactly one (67 of 103), so this is one email per seller per night, not a stream.
class AlertSellersOfUndeliveredReceiptsJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  # Rows are judged in id order from a stored cursor. `sent_at` has no index on `email_infos` (a table
  # past a billion rows), so a date-range scan is not available; the primary key is, and receipt rows
  # are written in send order.
  BATCH_SIZE = 5_000

  # The work bound for one run. Reaching it is normal on a first run and after an outage; the cursor
  # persists, so the next run continues rather than skipping what this one did not reach.
  MAX_ROWS_PER_RUN = 200_000

  # Where a first run starts when no cursor exists: recent enough to be actionable, since a seller
  # cannot do anything useful about a buyer from months ago.
  INITIAL_LOOKBACK = 7.days

  # How many previously-failed notices one run picks back up. The set is empty in normal operation;
  # the bound is there so a bad night for the mail transport cannot make the next run unbounded.
  MAX_RETRIES_PER_RUN = 1_000

  def perform
    cursor = current_cursor
    return if cursor.nil?

    last_judged = cursor
    scanned = 0
    by_seller = {}

    collect_pending_retries(by_seller)

    catch(:stop) do
      while scanned < MAX_ROWS_PER_RUN
        rows = candidate_rows(last_judged)
        throw :stop if rows.empty?

        rows.each do |row|
          # Stop AT the first row too young to judge, not after it. `partition` would let a settled
          # row later in the same batch move the cursor past this one, and the next run queries after
          # the cursor — the skipped row is then never reconsidered and its seller never told.
          throw :stop unless judgeable?(row)

          collect(row, by_seller)
          scanned += 1
          last_judged = row.id
          throw :stop if scanned >= MAX_ROWS_PER_RUN
        end
      end
    end

    notify(by_seller)
    save_cursor(last_judged)
  end

  private
    # Buyers a previous run claimed and then could not send to. The cursor is already past their
    # `email_infos` rows and the scan only ever moves forward, so nothing else would ever look at
    # them again. Anything no longer worth an email leaves the set here rather than being re-judged
    # every night forever.
    def collect_pending_retries(by_seller)
      purchase_ids = UndeliveredReceiptNotifier.pending_retry_purchase_ids(MAX_RETRIES_PER_RUN)
      return if purchase_ids.empty?

      purchases = Purchase.where(id: purchase_ids).includes(:url_redirect).index_by(&:id)
      resolved = purchase_ids.select do |purchase_id|
        purchase = purchases[purchase_id]
        # A purchase that no longer exists has no seller to tell and no row to come back on.
        next true if purchase.nil?

        collect_purchase(purchase, by_seller) == :resolved
      end

      UndeliveredReceiptNotifier.clear_pending_retry(resolved)
    end

    def judgeable?(row)
      row.sent_at.present? && row.sent_at <= UndeliveredReceiptNotifier::SETTLE_GRACE.ago
    end

    def candidate_rows(after_id)
      EmailInfo.where(type: CustomerEmailInfo.name, email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD)
               .where(state: %w[sent bounced])
               .where("email_infos.id > ?", after_id)
               .order(:id)
               .limit(BATCH_SIZE)
               .select(:id, :purchase_id, :state, :sent_at, :delivered_at, :opened_at)
    end

    # The seller is resolved through the purchase, so a charge-keyed row (no `purchase_id`) needs its
    # `email_info_charges` join. Each row is re-judged against live records here, because the scan
    # selected on state alone.
    def collect(row, by_seller)
      purchase = purchase_for(row)
      return if purchase.nil?

      collect_purchase(purchase, by_seller)
    end

    # Answers what this buyer's notice needs now: `:collected` to be named in this run's digest,
    # `:resolved` when there is nothing left to tell the seller, or `:unknown` when the send-once
    # store could not be read. The retry path drops a buyer only on `:resolved` — treating an
    # unreadable store as "done" would lose exactly the notices that set exists to keep.
    def collect_purchase(purchase, by_seller)
      notified = UndeliveredReceiptNotifier.notified?(purchase.id)
      return :unknown if notified.nil?
      return :resolved if notified
      return :resolved unless UndeliveredReceiptNotifier.undelivered?(purchase)

      seller = purchase.seller
      return :resolved if seller.nil? || seller.suspended? || seller.deleted?

      (by_seller[seller.id] ||= []) << purchase.id
      :collected
    end

    def purchase_for(row)
      return Purchase.find_by(id: row.purchase_id) if row.purchase_id.present?

      charge_id = EmailInfoCharge.where(email_info_id: row.id).pick(:charge_id)
      return nil if charge_id.nil?

      Charge.find_by(id: charge_id)&.purchase_as_orderable
    end

    def notify(by_seller)
      by_seller.each do |seller_id, purchase_ids|
        # The full set, untruncated: the mailer re-judges every buyer, and only then cuts the list
        # down. Truncating here would let ten recovered buyers suppress a digest an eleventh needed.
        # The mailer also claims and settles the send-once record, so nothing is marked notified for a
        # message that never left. Deduplicated because a buyer carried over from the retry set can
        # also be reached by this run's scan.
        ContactingCreatorMailer.undelivered_receipts(seller_id, purchase_ids.uniq).deliver_later(queue: "low")
      rescue => e
        # One seller's failure must not cost the rest their notice — nothing re-enqueues them, since
        # the sweep advances its cursor past these rows.
        ErrorNotifier.notify(e)
      end
    end

    def current_cursor
      stored = $redis.get(RedisKey.undelivered_receipt_sweep_cursor)
      return stored.to_i if stored.present?

      initial_cursor
    rescue => e
      # Without a cursor there is no safe start: resuming from zero would walk the whole table and
      # re-report every seller in it.
      ErrorNotifier.notify(e)
      nil
    end

    # Lowest receipt row id at least INITIAL_LOOKBACK old, found by walking back from the newest id
    # rather than filtering on the unindexed `sent_at`.
    def initial_cursor
      newest = EmailInfo.order(id: :desc).limit(1).pick(:id)
      return 0 if newest.nil?

      [newest - INITIAL_LOOKBACK.in_days.to_i * daily_row_estimate, 0].max
    end

    # Deliberately an estimate: it only decides where a first run starts, and the notified-once record
    # bounds what a too-generous guess can send.
    def daily_row_estimate = 400_000

    def save_cursor(cursor_id)
      $redis.set(RedisKey.undelivered_receipt_sweep_cursor, cursor_id)
    rescue => e
      ErrorNotifier.notify(e)
    end
end
