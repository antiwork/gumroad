# frozen_string_literal: true

# The last check before a post reaches the provider: each follower recipient's follow is read again and
# share-locked until the provider call returns, so an unfollow either commits first and withholds them, or
# waits until the provider has the post. Buyers and affiliates pass through.
module PostFollowerHandoff
  LOCK_WAIT_SECONDS = 10

  # Raised before anything reaches the provider, so a retry hands nothing over twice.
  class LockUnavailable < ActiveRecord::LockWaitTimeout; end

  # Yields the recipients that may still be handed off and returns them; yields nothing when none may. The
  # follows are locked before the newsletter admission takes its cutover lock, the order every follow writer
  # uses, and both are held for the block. on_withheld gets the rest once the handoff has returned.
  def self.hold(post:, recipients:, admission: nil, on_withheld: nil, &handoff)
    return recipients if recipients.empty?

    follower_ids = recipients.filter_map { _1[:follower]&.id }.uniq
    return admit(recipients, admission, &handoff) if follower_ids.empty?

    withheld = []
    admitted = ApplicationRecord.connected_to(role: :writing) do
      ApplicationRecord.transaction do
        live_emails = lock_live_follows(post.seller_id, follower_ids)
        kept, withheld = recipients.partition { (follower = _1[:follower]).nil? || still_at_address?(live_emails[follower.id], _1[:email]) }
        kept.empty? ? kept : admit(kept, admission, &handoff)
      end
    end
    if withheld.any?
      Rails.logger.info("[PostFollowerHandoff] post_id=#{post.id} withheld #{withheld.size} recipients whose follow ended")
      on_withheld&.call(withheld)
    end
    admitted
  end

  # Follows keep the address as it was typed, while audience rows (a blast's recipients) store it stripped and
  # lowercased. A follow with no live row never matches.
  def self.still_at_address?(live_email, recipient_email)
    live_email.present? && live_email.strip.downcase == recipient_email.to_s.strip.downcase
  end
  private_class_method :still_at_address?

  def self.admit(recipients, admission, &handoff)
    admission ? admission.call { handoff.call(recipients) } : handoff.call(recipients)
    recipients
  end
  private_class_method :admit

  # Returns id => email for the follows still live at this seller. A locking read finds no row for an id that
  # is gone and leaves a gap lock in its place, which at the top of the table would hold back every new follow
  # until the provider returns, so only rows that exist are locked.
  def self.lock_live_follows(seller_id, follower_ids)
    connection = Follower.connection
    previous = connection.select_value("SELECT @@SESSION.innodb_lock_wait_timeout")
    connection.execute("SET SESSION innodb_lock_wait_timeout = #{LOCK_WAIT_SECONDS}")
    existing_ids = Follower.where(id: follower_ids).pluck(:id)
    return {} if existing_ids.empty?

    Follower.active.where(id: existing_ids, followed_id: seller_id).lock("FOR SHARE").pluck(:id, :email).to_h
  rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked => e
    raise LockUnavailable, e.message
  ensure
    connection.execute("SET SESSION innodb_lock_wait_timeout = #{previous.to_i}") if previous.present?
  end
  private_class_method :lock_live_follows
end
