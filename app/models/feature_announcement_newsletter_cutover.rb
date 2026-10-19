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

  belongs_to :seller, class_name: "User"

  validates :state, inclusion: { in: STATES }

  def self.tracks_opt_outs_for?(seller_id)
    where(seller_id:, state: TRACKING_STATES).exists?
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
    email = email.to_s.strip
    confirmed = email.empty? ? [] : User.where(email:).where.not(confirmed_at: nil).limit(2).to_a
    confirmed.first if confirmed.one?
  end

  # For a save that lifts a buyer opt-out retire! may already have counted as resolved. Locks the follow (the
  # migration's order), share-locks the cutover row so retire! orders against this commit, then stamps the
  # follow after that lock so retire!'s recheck of rows changed since its scan includes it.
  def self.fence_buyer_resubscribe(seller_id, email)
    ApplicationRecord.connected_to(role: :writing) do
      uncached do
        next if email.blank? || !where(seller_id:).exists?

        follower_id = Follower.where(followed_id: seller_id, email:).pick(:id)
        next unless follower_id

        follower = Follower.lock.find(follower_id)

        where(seller_id:).lock("FOR SHARE").pick(:state)
        follower.update_columns(updated_at: Time.current)
      end
    end
  end

  # A contact opt-out for the newsletter seller after the copy. Feature announcements delivery reads only
  # its own preference, so the opt-out is written there for the account the old cancel link would reach.
  # Nothing reads the purchase veto later, so a newer Settings opt-in still wins.
  def self.mirror_buyer_opt_out(seller_id, email)
    ApplicationRecord.connected_to(role: :writing) do
      uncached do
        next if email.blank? || !tracks_opt_outs_for?(seller_id)

        follower = Follower.find_by(followed_id: seller_id, email:)
        user = follower ? subscriber_for(follower) : only_confirmed_account(email)
        FeatureAnnouncementSubscription.unsubscribe!(user, source: "newsletter_opt_out") if user
      end
    end
  end

  # For an account write that can change how retire! classifies the follows mapped to it (linked, or at its
  # old or new address). Runs inside the user's save, so the order is user, then follows, then the cutover
  # row; the stamp after the share lock puts them in retire!'s recheck. Retired is final, so it's skipped.
  def self.fence_account_change(user_id, emails)
    ApplicationRecord.connected_to(role: :writing) do
      uncached do
        seller_ids = where.not(state: "retired").pluck(:seller_id)
        next if seller_ids.empty?

        follower_ids = Follower.where(followed_id: seller_ids, follower_user_id: user_id).pluck(:id) |
          Follower.where(followed_id: seller_ids, email: emails.compact_blank.uniq).pluck(:id)
        next if follower_ids.empty?

        Follower.where(id: follower_ids).order(:id).lock.pluck(:id)
        where(seller_id: seller_ids).order(:id).lock("FOR SHARE").pluck(:state)
        Follower.where(id: follower_ids).update_all(updated_at: Time.current)
      end
    end
  end

  # Follower and audience posts of a seller with a cutover row hand off through admit_newsletter_handoff.
  # Nil for everything else, so other creators and the seller's customer posts take no lock.
  def self.handoff_admission_for(post)
    return unless post.audience_type? || post.follower_type?
    return unless ApplicationRecord.connected_to(role: :writing) { uncached { where(seller_id: post.seller_id).exists? } }

    ->(&handoff) { admit_newsletter_handoff(post.seller_id, &handoff) }
  end

  # Holds the cutover row FOR SHARE across the provider call only: retire! waits for an admitted handoff,
  # and a handoff after it commits raises Retired before anything reaches the provider.
  def self.admit_newsletter_handoff(seller_id)
    ApplicationRecord.connected_to(role: :writing) do
      transaction do
        state = with_lock_wait(HANDOFF_LOCK_WAIT_SECONDS) { uncached { where(seller_id:).lock("FOR SHARE").pick(:state) } }
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

  # For a save that would make a follow active. The share lock waits out a retire! holding the row
  # FOR UPDATE and reads its committed state, and holds retire! back until this save commits.
  # Sellers without a cutover row take no lock, so other creators' follows never queue here.
  def self.retired_for_follow?(seller_id)
    ApplicationRecord.connected_to(role: :writing) do
      uncached { where(seller_id:).exists? && where(seller_id:).lock("FOR SHARE").pick(:state) == "retired" }
    end
  end
end
