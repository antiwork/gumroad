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

  # How many buyers one email names before it summarizes. A seller with more than this has a systemic
  # problem the list would not help them read.
  MAX_LISTED_PER_SELLER = 10

  # Where a first run starts when no cursor exists: recent enough to be actionable, since a seller
  # cannot do anything useful about a buyer from months ago.
  INITIAL_LOOKBACK = 7.days

  def perform
    cursor = current_cursor
    return if cursor.nil?

    last_judged = cursor
    scanned = 0
    by_seller = {}

    while scanned < MAX_ROWS_PER_RUN
      rows = candidate_rows(last_judged)
      break if rows.empty?

      settled, unsettled = rows.partition { |row| row.sent_at.present? && row.sent_at <= UndeliveredReceiptNotifier::SETTLE_GRACE.ago }
      # Stop at the first row too young to judge rather than skipping it: advancing past it would
      # decide its case by never looking at it again.
      settled.each { |row| collect(row, by_seller) }
      scanned += settled.size
      last_judged = settled.last.id if settled.any?
      break if unsettled.any?
    end

    notify(by_seller)
    save_cursor(last_judged)
  end

  private
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
      return if UndeliveredReceiptNotifier.notified?(purchase.id)
      return unless UndeliveredReceiptNotifier.undelivered?(purchase)

      seller = purchase.seller
      return if seller.nil? || seller.suspended? || seller.deleted?

      (by_seller[seller.id] ||= []) << purchase.id
    end

    def purchase_for(row)
      return Purchase.find_by(id: row.purchase_id) if row.purchase_id.present?

      charge_id = EmailInfoCharge.where(email_info_id: row.id).pick(:charge_id)
      return nil if charge_id.nil?

      Charge.find_by(id: charge_id)&.purchase_as_orderable
    end

    def notify(by_seller)
      by_seller.each do |seller_id, purchase_ids|
        ContactingCreatorMailer.undelivered_receipts(seller_id, purchase_ids.first(MAX_LISTED_PER_SELLER), purchase_ids.size)
                               .deliver_later(queue: "low")
        # Recorded for every purchase the sweep found, including those the email only counted: they
        # were reported, and re-finding them tomorrow would re-send the same summary.
        UndeliveredReceiptNotifier.record_sent(purchase_ids)
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
