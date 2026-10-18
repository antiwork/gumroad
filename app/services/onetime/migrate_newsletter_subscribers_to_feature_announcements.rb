# frozen_string_literal: true

# Subscribes followers of Gumroad's own newsletter to feature announcements (gumroad-private#3664).
# Writes stay disabled until the newsletter's history is audited; dry-run counts are not permission.
# Only an account-linked follow at the account's confirmed email qualifies, and no existing row is overwritten.
class Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements
  NEWSLETTER_SELLER_EXTERNAL_ID = "6282492303727"
  NEWSLETTER_SELLER_USERNAME = "gumroad"
  WRITES_ENABLED = false
  BATCH_SIZE = 1_000

  class SourceUnverified < StandardError; end
  class WritesDisabled < StandardError; end

  def self.process(cutoff_at:, dry_run: true, batch_size: BATCH_SIZE)
    new(cutoff_at:, dry_run:, batch_size:).process
  end

  def initialize(cutoff_at:, dry_run:, batch_size:)
    raise ArgumentError, "cutoff_at is required" unless cutoff_at.is_a?(Time) || cutoff_at.is_a?(ActiveSupport::TimeWithZone)

    @cutoff_at = cutoff_at
    @dry_run = dry_run
    @batch_size = batch_size
    @counts = Hash.new(0)
  end

  def process
    raise WritesDisabled, "Newsletter migration writes are disabled until the source is audited" if !@dry_run && !WRITES_ENABLED

    seller = verified_seller!
    cohort(seller).in_batches(of: @batch_size) do |batch|
      followers = batch.to_a
      users = User.where(id: followers.filter_map(&:follower_user_id)).index_by(&:id)
      shared_emails = User.where(email: followers.map(&:email)).group(:email).having("COUNT(*) > 1").count.keys.map(&:downcase).to_set
      preferences = FeatureAnnouncementSubscription.where(user_id: users.keys).pluck(:user_id).to_set

      followers.each do |follower|
        outcome = classify(follower, users[follower.follower_user_id], shared_emails, preferences)
        outcome = apply(seller, follower) if outcome == :eligible && !@dry_run
        @counts[outcome] += 1
      end
    end

    Rails.logger.info("[MigrateNewsletterSubscribersToFeatureAnnouncements] dry_run=#{@dry_run} cutoff_at=#{@cutoff_at.iso8601} counts=#{@counts}")
    { dry_run: @dry_run, cutoff_at: @cutoff_at, counts: @counts.dup }
  end

  private
    def verified_seller!
      seller = User.find_by(external_id: NEWSLETTER_SELLER_EXTERNAL_ID)
      unless seller&.read_attribute(:username) == NEWSLETTER_SELLER_USERNAME && seller.account_active?
        raise SourceUnverified, "Newsletter seller #{NEWSLETTER_SELLER_EXTERNAL_ID} is not the active @#{NEWSLETTER_SELLER_USERNAME} account"
      end
      seller
    end

    def cohort(seller)
      Follower.active.where(followed_id: seller.id).where("followers.confirmed_at <= ? AND followers.created_at <= ?", @cutoff_at, @cutoff_at)
    end

    def classify(follower, user, shared_emails, preferences)
      return :guest if follower.follower_user_id.nil?
      return :unmatched_account if user.nil?
      return :inactive_account unless user.account_active?
      return :unconfirmed_account unless user.confirmed?
      return :conflicting_address unless same_address?(user.email, follower.email)
      return :ambiguous_address if shared_emails.include?(follower.email.to_s.strip.downcase)
      return :existing_preference if preferences.include?(user.id)

      :eligible
    end

    # Rechecks the follower and account under lock, so an opt-out or email change made after
    # the batch was read wins. Lock order matches FeatureAnnouncementDelivery: user first.
    def apply(seller, follower)
      ReplicaLagWatcher.watch
      ApplicationRecord.transaction do
        user = User.lock("FOR SHARE").find_by(id: follower.follower_user_id)
        current = Follower.lock("FOR SHARE").find_by(id: follower.id)
        still_eligible = user&.account_active? && user.confirmed? && current &&
          cohort(seller).where(id: current.id).exists? && same_address?(user.email, current.email)
        next :changed_since_read unless still_eligible

        now = Time.current
        # insert_all skips a row whose user_id already exists, whatever it holds.
        FeatureAnnouncementSubscription.insert_all(
          [{ user_id: user.id, subscribed: true, version: 1, source: "newsletter_migration", created_at: now, updated_at: now }]
        )
        :migrated
      end
    end

    def same_address?(account_email, follower_email)
      account_email.present? && account_email.strip.casecmp?(follower_email.to_s.strip)
    end
end
