# frozen_string_literal: true

# Populates the `subscription_current_email` and `subscription_current_email_domain` search fields
# on memberships that predate them.
#
# The field is written by callbacks that only fire on a future account-email change or subscription
# reassignment, so a member whose email changed BEFORE the field existed stays unfindable by the
# address the seller has in hand — the exact ticket that motivated it.
#
# Run it AFTER AddSubscriptionCurrentEmailToPurchasesIndex: the purchases mapping is
# `dynamic: :strict`, so before that migration every write carrying the field 400s.
#
# Only memberships whose indexed `email` already differs from the member's current account email are
# reindexed. The rest are findable by `email` today and get the field for free the next time the
# member changes their address, so widening the scope would buy nothing and cost millions of writes.
#
# The SQL predicate is a deliberately wide prefilter (it fires if EITHER the confirmed or the
# unconfirmed address differs); `Subscription#email` makes the actual call, so the pick between the
# two stays on the production method rather than on a copy of `form_email` in SQL.
#
#   Onetime::BackfillSubscriptionCurrentEmail.process(dry_run: true)
#   Onetime::BackfillSubscriptionCurrentEmail.process(seller_id: 123)
#   Onetime::BackfillSubscriptionCurrentEmail.process
class Onetime::BackfillSubscriptionCurrentEmail
  BATCH_SIZE = 1_000
  FIELDS = %w[subscription_current_email subscription_current_email_domain].freeze
  # Spread each batch's index writes so a backfill cannot starve live indexing.
  BATCH_INTERVAL_SECONDS = 10

  def self.process(batch_size: BATCH_SIZE, seller_id: nil, dry_run: false)
    new(batch_size:, seller_id:, dry_run:).process
  end

  def initialize(batch_size: BATCH_SIZE, seller_id: nil, dry_run: false)
    @batch_size = batch_size
    @seller_id = seller_id
    @dry_run = dry_run
  end

  def process
    scanned = 0
    stale = 0
    seconds_offset = 0

    scope.find_in_batches(batch_size:) do |purchases|
      ReplicaLagWatcher.watch unless dry_run

      scanned += purchases.size
      ids = purchases.select { stale_current_email?(_1) }.map(&:id)
      stale += ids.size
      next if ids.empty? || dry_run

      Sidekiq::Client.push_bulk(
        "class" => ElasticsearchIndexerWorker,
        "args" => ids.map { ["update", { "record_id" => _1, "class_name" => "Purchase", "fields" => FIELDS }] },
        "queue" => "low",
        "at" => seconds_offset.seconds.from_now.to_i,
      )
      seconds_offset += BATCH_INTERVAL_SECONDS
    end

    Rails.logger.info("[#{self.class.name}] scanned=#{scanned} #{dry_run ? 'would_reindex' : 'reindexed'}=#{stale}")
    { scanned:, reindexed: stale }
  end

  private
    attr_reader :batch_size, :seller_id, :dry_run

    def scope
      relation = Purchase
        .is_original_subscription_purchase
        .not_is_archived_original_subscription_purchase
        .joins(subscription: :user)
        .where(
          "LOWER(users.email) != LOWER(purchases.email) OR (users.unconfirmed_email IS NOT NULL AND LOWER(users.unconfirmed_email) != LOWER(purchases.email))"
        )
      relation = relation.where(seller_id:) if seller_id
      relation
    end

    def stale_current_email?(purchase)
      current = purchase.subscription&.email&.downcase
      current.present? && current != purchase.email&.downcase
    end
end
