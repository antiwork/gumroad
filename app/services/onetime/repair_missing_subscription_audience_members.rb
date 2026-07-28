# frozen_string_literal: true

# Repairs paying subscribers who are missing from their creator's audience.
#
# Unsubscribing used to destroy the buyer's `audience_members` row, and re-subscribing never
# rebuilt it (see Purchase::AudienceMember#update_audience_member_details for the full story).
# Those buyers keep getting charged while every post, blast, and workflow silently skips them,
# because all send paths resolve recipients through `AudienceMember.filter`.
#
# This finds active subscriptions whose original purchase SHOULD be in the audience but is not
# represented there, and rebuilds the row from live state. It is idempotent: rebuilding an
# already-correct row is a no-op, so it is safe to re-run.
#
#   Onetime::RepairMissingSubscriptionAudienceMembers.process              # repair
#   Onetime::RepairMissingSubscriptionAudienceMembers.process(dry_run: true) # report only
class Onetime::RepairMissingSubscriptionAudienceMembers
  BATCH_SIZE = 1_000

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
    repaired = 0

    scope.find_each(batch_size:) do |purchase|
      scanned += 1
      next unless purchase.should_be_audience_member?
      next if represented_in_audience?(purchase)

      repaired += 1
      next if dry_run

      ReplicaLagWatcher.watch
      purchase.rebuild_audience_member_details
    end

    Rails.logger.info(
      "[#{self.class.name}] scanned=#{scanned} #{dry_run ? 'would_repair' : 'repaired'}=#{repaired}"
    )
    { scanned:, repaired: }
  end

  private
    attr_reader :batch_size, :seller_id, :dry_run

    def scope
      relation = Purchase
        .is_original_subscription_purchase
        .not_is_archived_original_subscription_purchase
        .where(can_contact: true)
        .joins(:subscription)
        .where(subscriptions: { deactivated_at: nil })
      relation = relation.where(seller_id:) if seller_id
      relation
    end

    # Both known shapes of the bug: no audience_members row at all, and a row that exists but
    # omits this purchase (for instance when a follower or affiliate entry kept the row alive).
    def represented_in_audience?(purchase)
      member = AudienceMember.find_by(email: purchase.email.to_s.strip.downcase, seller_id: purchase.seller_id)
      return false if member.nil?

      Array.wrap(member.details["purchases"]).any? { _1["id"] == purchase.id }
    end
end
