# frozen_string_literal: true

# Moving one seller's newsletter into Feature announcements (gumroad-private#3664), driven by
# Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements. Retirement is only reachable from
# `migrated`, so the old newsletter can't be turned off before consent rows exist.
class FeatureAnnouncementNewsletterCutover < ApplicationRecord
  STATES = %w[prepared migrating migrated failed retired rolled_back].freeze
  APPLICABLE_STATES = %w[prepared migrating failed].freeze
  # Rolled back means nothing was carried over, so old opt-outs no longer need mirroring.
  TRACKING_STATES = STATES - %w[rolled_back]
  HANDOFF_LOCK_WAIT_SECONDS = 10

  # Raised at a provider handoff of an old-newsletter post once the newsletter is retired.
  class Retired < StandardError; end
  # Raised when a handoff gives up waiting for the barrier, so the caller knows the provider was never called.
  # A LockWaitTimeout, so retries and existing rescues treat it as before.
  class AdmissionTimeout < ActiveRecord::LockWaitTimeout; end

  belongs_to :seller, class_name: "User"

  validates :state, inclusion: { in: STATES }

  def self.tracks_opt_outs_for?(seller_id)
    where(seller_id:, state: TRACKING_STATES).exists?
  end

  def self.official_seller_id
    User.where(external_id: Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements::NEWSLETTER_SELLER_EXTERNAL_ID).pick(:id)
  end

  # Gumroad's own newsletter seller, whose writers order against its cutover even before the row exists, and
  # any seller that already has a row.
  def self.covers?(seller_id)
    seller_id.present? && (seller_id == official_seller_id || where(seller_id:).exists?)
  end

  # The row's current state, nil without one, read FOR SHARE inside the caller's transaction. With no row the
  # read holds a gap lock on the seller_id index under REPEATABLE READ (which the cutover checks for), so
  # prepare! can't create it until the caller commits; with a row, retire! waits the same way.
  def self.locked_state(seller_id)
    ApplicationRecord.connected_to(role: :writing) { uncached { where(seller_id:).lock("FOR SHARE").pick(:state) } }
  end

  # Primary and uncached: senders run on workers whose plain reads can go to a lagging replica.
  def self.retired_for?(seller_id)
    ApplicationRecord.connected_to(role: :writing) { uncached { where(seller_id:, state: "retired").exists? } }
  end

  # The account a newsletter follow maps to, the same way the migration maps it: the recorded link, read
  # with a lock so a link the migration bound after this record was loaded still counts, else the only
  # confirmed account at the address. Nil when none or several.
  def self.subscriber_for(follower)
    uncached do
      linked_id = Follower.where(id: follower.id).lock("FOR SHARE").pick(:follower_user_id)
      linked_id ? User.find_by(id: linked_id) : only_confirmed_account(follower.email)
    end
  end

  def self.only_confirmed_account(email)
    email = email.to_s.strip.downcase
    # SQL collation can match different full addresses; apply the cap after the exact match.
    confirmed = email.empty? ? [] : User.where(email:).where.not(confirmed_at: nil).to_a.select { _1.email.to_s.strip.downcase == email }.take(2)
    confirmed.first if confirmed.one?
  end

  # For a save that lifts a buyer opt-out the copy or retire! may have counted. Locks the follow (the migration's
  # order; a current read, and with no follow none can be added at the address until this commits), then the
  # cutover barrier, then stamps the follow after it so retire!'s recheck of rows changed since its scan sees it.
  def self.fence_buyer_resubscribe(seller_id, email)
    ApplicationRecord.connected_to(role: :writing) do
      uncached do
        next if email.blank? || !covers?(seller_id)

        emails = [email, email.to_s.strip.downcase].uniq
        follower_ids = Follower.where(followed_id: seller_id, email: emails).order(:id).lock.pluck(:id)
        next if follower_ids.empty?

        locked_state(seller_id)
        Follower.where(id: follower_ids).update_all(updated_at: Time.current)
      end
    end
  end

  # A contact opt-out for the newsletter seller after the copy. Feature announcements delivery reads only
  # its own preference, so the opt-out is written there for the account the old cancel link would reach.
  # Nothing reads the purchase veto later, so a newer Settings opt-in still wins.
  def self.mirror_buyer_opt_out(seller_id, email)
    ApplicationRecord.connected_to(role: :writing) do
      uncached do
        next if email.blank? || !covers?(seller_id)

        normalized_email = email.to_s.strip.downcase
        follower = nil
        [email, normalized_email].uniq.each do |address|
          candidate = Follower.where(followed_id: seller_id, email: address).lock("FOR SHARE").first
          next unless candidate && candidate.email.to_s.strip.downcase == normalized_email

          follower = candidate
          break
        end
        # A visible tracking row needs no lock, so the common path never waits on retire!. Otherwise the barrier
        # either holds prepare! back (no row, so the copy then reads this opt-out) or finds a row this snapshot missed.
        next unless tracks_opt_outs_for?(seller_id) || TRACKING_STATES.include?(locked_state(seller_id))

        user = follower ? subscriber_for(follower) : only_confirmed_account(email)
        FeatureAnnouncementSubscription.unsubscribe!(user, source: "newsletter_opt_out") if user
      end
    end
  end

  # For an account write that can change how the copy or retire! classifies follows at its old or new address.
  # A linked follow elsewhere is a conflicting address whatever the account's state, so the addresses are enough.
  # Runs inside the user's save: the user, then those follows (a current read, so none can be added there before
  # this commits), then the cutover barrier, then a stamp retire!'s recheck sees. Retired is final, so skipped.
  def self.fence_account_change(emails)
    ApplicationRecord.connected_to(role: :writing) do
      uncached do
        seller_ids = where.not(state: "retired").pluck(:seller_id)
        official_id = official_seller_id
        seller_ids |= [official_id] if official_id && !where(seller_id: official_id, state: "retired").exists?
        next if seller_ids.empty?

        follower_ids = Follower.where(followed_id: seller_ids, email: emails.compact_blank.uniq).lock.pluck(:id)
        next if follower_ids.empty?

        where(seller_id: seller_ids).order(:seller_id).lock("FOR SHARE").pluck(:state)
        Follower.where(id: follower_ids).update_all(updated_at: Time.current)
      end
    end
  end

  # Follower and audience posts of a seller with a cutover row hand off through admit_newsletter_handoff.
  # Nil for everything else, so other creators and the seller's customer posts take no lock.
  def self.handoff_admission_for(post)
    return unless post.audience_type? || post.follower_type?
    return unless ApplicationRecord.connected_to(role: :writing) { uncached { covers?(post.seller_id) } }

    ->(&handoff) { admit_newsletter_handoff(post.seller_id, &handoff) }
  end

  # Holds the cutover barrier across the provider call only: prepare! and retire! wait for an admitted handoff,
  # and a handoff after retirement commits raises Retired before anything reaches the provider.
  def self.admit_newsletter_handoff(seller_id)
    ApplicationRecord.connected_to(role: :writing) do
      transaction do
        state = begin
          with_lock_wait(HANDOFF_LOCK_WAIT_SECONDS) { locked_state(seller_id) }
        rescue ActiveRecord::LockWaitTimeout => e
          raise AdmissionTimeout, e.message
        end
        raise Retired, "The newsletter of seller #{seller_id} is retired" if state == "retired"

        yield
      end
    end
  end

  def self.with_lock_wait(seconds)
    previous = connection.select_value("SELECT @@SESSION.innodb_lock_wait_timeout")
    connection.execute("SET SESSION innodb_lock_wait_timeout = #{seconds.to_i}")
    yield
  ensure
    connection.execute("SET SESSION innodb_lock_wait_timeout = #{previous.to_i}") if previous.present?
  end
  private_class_method :with_lock_wait

  # For a save that would make a follow active. The barrier waits out a retire! holding the row FOR UPDATE and
  # reads its committed state, and holds prepare! and retire! back until this save commits. Other creators'
  # follows take no lock.
  def self.retired_for_follow?(seller_id)
    ApplicationRecord.connected_to(role: :writing) { uncached { covers?(seller_id) && locked_state(seller_id) == "retired" } }
  end
end
