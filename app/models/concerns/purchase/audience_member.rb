# frozen_string_literal: true

module Purchase::AudienceMember
  extend ActiveSupport::Concern

  included do
    after_save :update_audience_member_details
    after_destroy :remove_from_audience_member_details
  end

  class_methods do
    # Collects the buyers needing an audience rebuild inside the current
    # `deferring_audience_member_rebuilds` block, or nil when there is no block in progress.
    def pending_audience_member_rebuilds
      Thread.current[:pending_audience_member_rebuilds]
    end

    # Coalesces audience rebuilds for callers that flip can_contact on many purchase rows in a
    # loop. Each rebuild re-reads all of a buyer's purchases, so doing one per row is quadratic
    # in the number of rows. Inside this block rebuilds are recorded and de-duplicated, then run
    # once per buyer at the end. Nesting is safe: only the outermost block does the work.
    def deferring_audience_member_rebuilds
      return yield if pending_audience_member_rebuilds

      Thread.current[:pending_audience_member_rebuilds] = Set.new
      begin
        result = yield
        # Read the pending set before clearing it so the rebuilds below, which save records and
        # can re-enter this callback, run in normal immediate mode.
        buyers = Thread.current[:pending_audience_member_rebuilds]
        Thread.current[:pending_audience_member_rebuilds] = nil
        buyers.each do |email, seller_id|
          AudienceMember.find_or_initialize_by(email:, seller_id:).refresh!
        end
        result
      ensure
        Thread.current[:pending_audience_member_rebuilds] = nil
      end
    end
  end

  def should_be_audience_member?
    result = can_contact?
    result &= purchase_state.in?(%w[successful gift_receiver_purchase_successful not_charged])
    result &= !is_gift_sender_purchase?
    result &= EmailFormatValidator.valid?(email)
    if subscription_id.nil?
      result &= !stripe_refunded?
      result &= chargeback_date.blank? || chargeback_reversed?
    else
      result &= is_original_subscription_purchase?
      result &= !is_archived_original_subscription_purchase?
      result &= subscription.deactivated_at.nil?
      result &= !subscription.is_test_subscription?
    end
    result
  end

  def audience_member_details
    {
      id:,
      country: country_or_ip_country.to_s,
      created_at: created_at.iso8601,
      product_id: link_id,
      variant_ids: variant_attributes.ids,
      price_cents:,
      subscription_cancelled: subscription&.cancelled_at.present?,
      license_uses: license&.uses,
    }.compact_blank
  end

  def add_to_audience_member_details
    return unless should_be_audience_member?

    retried ||= false
    # `.lock` on retry forces InnoDB to take a fresh read of committed data instead of the
    # transaction's original repeatable-read snapshot, which otherwise still can't see the
    # winner's just-committed row and would raise the same RecordNotUnique again.
    member = retried ? AudienceMember.lock.find_or_initialize_by(email:, seller:) : AudienceMember.find_or_initialize_by(email:, seller:)
    member.details["purchases"] ||= []
    member.details["purchases"].delete_if { _1["id"] == id }
    member.details["purchases"] << audience_member_details
    member.save!
  rescue ActiveRecord::RecordNotUnique
    # Two concurrent saves for the same buyer (e.g. a double-submitted checkout) can both
    # find_or_initialize_by a fresh record and race to insert it. `retried ||=` (not `=`)
    # because `retry` re-runs this whole method body, including the assignment above.
    raise if retried
    retried = true
    retry
  rescue ActiveRecord::LockWaitTimeout => e
    # Concurrent writers already waited innodb_lock_wait_timeout on this row.
    # Retrying queues behind the same lock. The purchase write already committed.
    ErrorNotifier.notify(e)
  end

  def remove_from_audience_member_details(email = attributes["email"])
    member = AudienceMember.find_by(email:, seller:)
    return if member.nil?

    member.details["purchases"]&.delete_if { _1["id"] == id }
    member.valid? ? member.save! : member.destroy!
  rescue ActiveRecord::LockWaitTimeout => e
    ErrorNotifier.notify(e)
  end

  # Rebuilds the buyer's whole audience_members row from live purchase/follower/affiliate
  # state, instead of just adding or removing this one purchase from it.
  #
  # Inside a `Purchase.deferring_audience_member_rebuilds` block this only records that the
  # buyer needs rebuilding; the block does one rebuild per buyer when it finishes. Callers that
  # flip many purchase rows for the same buyer in a loop would otherwise pay for a full rebuild
  # per row, and each rebuild re-reads every one of that buyer's purchases.
  def rebuild_audience_member_details
    pending = Purchase.pending_audience_member_rebuilds
    return pending << [email, seller_id] if pending

    AudienceMember.find_or_initialize_by(email:, seller:).refresh!
  end

  private
    def update_audience_member_details
      return if !previous_changes.keys.intersect?(%w[can_contact purchase_state stripe_refunded flags chargeback_date email])
      remove_from_audience_member_details(email_previously_was) if email_previously_changed? && !previously_new_record?
      # Re-subscribing has to rebuild the buyer's audience_members row from scratch rather than
      # append this single purchase to it.
      #
      # Unsubscribing sets can_contact = false on EVERY purchase row for the (email, seller)
      # pair, and once the last contactable purchase is gone the audience_members row itself is
      # destroyed. Re-subscribing flips those rows back one at a time, and each row's callback
      # only ever knows about itself. Two things then go wrong: a row that is not an audience
      # member in its own right (a subscription renewal charge, which is skipped because only
      # the original purchase represents a subscription) contributes nothing at all, and any
      # purchase that was already contactable is never saved, so it never gets re-added. A buyer
      # can end up with no audience row at all while their subscription keeps billing, which
      # makes them invisible to every post, blast, and workflow the creator sends.
      return rebuild_audience_member_details if resubscribed?
      return remove_from_audience_member_details unless should_be_audience_member?

      add_to_audience_member_details
    end

    # True when this save is what flipped an existing purchase from unsubscribed back to
    # contactable. Excludes brand new rows, whose can_contact is "changed" simply by being set.
    def resubscribed?
      return false if previously_new_record?

      can_contact_previously_changed? && can_contact?
    end
end
