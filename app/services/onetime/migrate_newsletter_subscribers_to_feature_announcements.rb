# frozen_string_literal: true

# Carries subscribers of Gumroad's own newsletter into Feature announcements, then retires the old
# newsletter (gumroad-private#3664). Run in order: preflight → prepare! → apply!(confirmed_eligible_count:)
# → retire!. Nothing runs on its own; apply! needs the eligible count from the stored plan.
#
# Only a follow the person made and confirmed themselves, from a source in VERIFIED_SOURCES, linked to an
# account whose confirmed email is the followed address, is carried over. Every other row is counted and
# left alone, and an existing preference row (including an opt-out) is never overwritten.
class Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements
  NEWSLETTER_SELLER_EXTERNAL_ID = "6282492303727"
  NEWSLETTER_SELLER_USERNAME = "gumroad"
  # CSV imports, rows with no source and any later source record who was added, not who asked.
  EXPRESS_SOURCES = [Follower::From::EMBED_FORM, Follower::From::FOLLOW_PAGE, Follower::From::PROFILE_PAGE].freeze
  # Candidates only: what a source value means today doesn't prove how this newsletter's old rows were made.
  # Each entry maps an EXPRESS_SOURCES value to the reviewed evidence of its history; apply! refuses while empty.
  VERIFIED_SOURCES = {}.freeze
  # Outcomes where retiring the old newsletter takes no mail anyone still wants.
  RESOLVED_OUTCOMES = %i[follower_inactive existing_preference buyer_opted_out].freeze
  # Reviewed decisions for any other cohort (outcome => decision reference); retire! refuses until all are covered.
  RETIREMENT_RESOLUTIONS = {}.freeze
  BATCH_SIZE = 1_000
  RUN_LOCK_TIMEOUT_SECONDS = 0

  class SourceUnverified < StandardError; end
  class InvalidTransition < StandardError; end
  class PlanMismatch < StandardError; end
  class AlreadyRunning < StandardError; end
  class CoverageIncomplete < StandardError; end

  def self.preflight(cutoff_at:, batch_size: BATCH_SIZE) = new(batch_size:).preflight(cutoff_at)
  def self.prepare!(cutoff_at:, batch_size: BATCH_SIZE) = new(batch_size:).prepare!(cutoff_at)
  def self.apply!(confirmed_eligible_count:, batch_size: BATCH_SIZE) = new(batch_size:).apply!(confirmed_eligible_count)
  def self.retire! = new.retire!
  def self.rollback!(batch_size: BATCH_SIZE) = new(batch_size:).rollback!

  def initialize(batch_size: BATCH_SIZE)
    @batch_size = batch_size
  end

  # Read-only: every follower of the newsletter seller, counted by outcome. Counts are not permission;
  # `unverified_source` rows would be eligible if their source were in VERIFIED_SOURCES.
  def preflight(cutoff_at)
    on_primary do
      seller = verified_seller!
      { seller_id: seller.id, cutoff_at:, verified_sources: verified_sources!, counts: outcome_counts(seller, cutoff_at, Follower.all) }
    end
  end

  def prepare!(cutoff_at)
    raise ArgumentError, "cutoff_at must be in the past" unless cutoff_at.is_a?(Time) && cutoff_at <= Time.current

    on_primary do
      with_run_lock(verified_seller!) do
        report = preflight(cutoff_at)
        cutover = FeatureAnnouncementNewsletterCutover.find_or_initialize_by(seller_id: report[:seller_id])
        if cutover.persisted? && !%w[prepared failed migrated rolled_back].include?(cutover.state)
          raise InvalidTransition, "Cutover is #{cutover.state}; only a prepared, failed, migrated or rolled back plan can be replaced"
        end

        # A replaced failed or migrated plan keeps its migrated_count: those rows exist, and a rerun skips them.
        # Replacing a migrated plan with a later cutoff is how follows made after the first cutoff are carried over.
        cutover.update!(state: "prepared", cutoff_at:, counts: report[:counts], eligible_count: report[:counts].fetch(:eligible, 0),
                        verified_sources: report[:verified_sources], cursor_follower_id: 0, error: nil, retirement_coverage: nil)
        cutover
      end
    end
  end

  # Resumable: each carried-over row and its count commit together, so a failed or interrupted run
  # continues from its cursor with an exact migrated_count, and a rerun never writes a row twice.
  def apply!(confirmed_eligible_count)
    on_primary do
      seller = verified_seller!
      with_run_lock(seller) do
        cutover = FeatureAnnouncementNewsletterCutover.find_by!(seller_id: seller.id)
        raise InvalidTransition, "Cutover is #{cutover.state}" unless FeatureAnnouncementNewsletterCutover::APPLICABLE_STATES.include?(cutover.state)
        raise SourceUnverified, "No follower source has verified provenance (VERIFIED_SOURCES is empty)" if verified_sources!.empty?
        raise SourceUnverified, "Plan was prepared with other verified sources; prepare it again" unless cutover.verified_sources == VERIFIED_SOURCES
        raise PlanMismatch, "Plan has #{cutover.eligible_count} eligible, not #{confirmed_eligible_count}" unless cutover.eligible_count == confirmed_eligible_count

        cutover.update!(state: "migrating", error: nil)
        begin
          Follower.where(followed_id: seller.id).where("id > ?", cutover.cursor_follower_id).in_batches(of: @batch_size) do |batch|
            ReplicaLagWatcher.watch
            followers = batch.to_a
            followers.each { migrate(seller, cutover, _1) }
            cutover.update_columns(cursor_follower_id: followers.map(&:id).max, updated_at: Time.current)
          end
          cutover.reload.update!(state: "migrated")
        rescue StandardError => e
          cutover.update_columns(state: "failed", error: "#{e.class}: #{e.message}".first(255), updated_at: Time.current)
          raise
        end
        cutover
      end
    end
  end

  # Turns off the old newsletter: new follows of the seller are refused and its audience and follower
  # posts stop sending. Existing follower rows are left as they are. Refused, with the coverage recorded,
  # while any follower falls outside RESOLVED_OUTCOMES and RETIREMENT_RESOLUTIONS.
  def retire!
    on_primary do
      seller = verified_seller!
      with_run_lock(seller) do
        cutover = FeatureAnnouncementNewsletterCutover.find_by!(seller_id: seller.id)
        raise InvalidTransition, "Cutover is #{cutover.state}, not migrated" unless cutover.state == "migrated"

        scan_started_at = Time.current.change(usec: 0)
        counts = outcome_counts(seller, cutover.cutoff_at, Follower.all)
        coverage = nil
        transition!(from: %w[migrated], to: "retired", retired_at: Time.current) do |locked|
          # followers.updated_at has whole seconds; rows changed while the scan ran are classified again.
          coverage = retirement_coverage(counts, outcome_counts(seller, cutover.cutoff_at, Follower.where("updated_at >= ?", scan_started_at)))
          locked.retirement_coverage = coverage
          raise CoverageIncomplete, "Retirement would drop unresolved subscribers: #{coverage[:unresolved]}" if coverage[:unresolved].any?
        end
      rescue CoverageIncomplete
        # Kept after the refusal rolls back, so the plan shows which cohorts still block retirement.
        cutover.update_columns(retirement_coverage: coverage, updated_at: Time.current) if coverage
        raise
      end
    end
  end

  # Removes only rows this migration wrote and nobody has changed since (still version 1, subscribed).
  def rollback!
    on_primary do
      seller = verified_seller!
      with_run_lock(seller) do
        cutover = FeatureAnnouncementNewsletterCutover.find_by!(seller_id: seller.id)
        raise InvalidTransition, "A retired newsletter can't be rolled back" if cutover.state == "retired"

        FeatureAnnouncementSubscription.where(source: "newsletter_migration", subscribed: true, version: 1)
          .in_batches(of: @batch_size) { _1.delete_all }
        cutover.update!(state: "rolled_back", migrated_count: 0, cursor_follower_id: 0)
        cutover
      end
    end
  end

  private
    def on_primary(&) = ApplicationRecord.connected_to(role: :writing, &)

    def verified_seller!
      seller = User.find_by(external_id: NEWSLETTER_SELLER_EXTERNAL_ID)
      unless seller&.read_attribute(:username) == NEWSLETTER_SELLER_USERNAME && seller.account_active?
        raise SourceUnverified, "Newsletter seller #{NEWSLETTER_SELLER_EXTERNAL_ID} is not the active @#{NEWSLETTER_SELLER_USERNAME} account"
      end
      seller
    end

    def transition!(from:, to:, **attributes)
      FeatureAnnouncementNewsletterCutover.transaction do
        cutover = FeatureAnnouncementNewsletterCutover.lock.find_by!(seller_id: verified_seller!.id)
        raise InvalidTransition, "Cutover is #{cutover.state}, not #{from.join(" or ")}" unless from.include?(cutover.state)

        yield cutover if block_given?
        cutover.update!(state: to, **attributes)
        cutover
      end
    end

    # A row changed during the scan is counted in both passes, so unresolved counts are lower bounds per outcome.
    def retirement_coverage(counts, changed)
      resolutions = retirement_resolutions!
      unresolved = counts.merge(changed) { |_, full, recheck| [full, recheck].max }
        .reject { |outcome, _| RESOLVED_OUTCOMES.include?(outcome) || resolutions.key?(outcome) }
      { checked_at: Time.current, counts:, changed_during_scan: changed, resolutions:, unresolved: }
    end

    def verified_sources!
      invalid = VERIFIED_SOURCES.reject { |source, evidence| EXPRESS_SOURCES.include?(source) && evidence.present? }
      raise SourceUnverified, "Only express sources with recorded evidence can be verified: #{invalid.keys}" if invalid.any?

      VERIFIED_SOURCES
    end

    def retirement_resolutions!
      invalid = RETIREMENT_RESOLUTIONS.select { |outcome, decision| outcome == :eligible || decision.blank? }
      raise CoverageIncomplete, "Eligible subscribers must be migrated, and every resolution needs a decision: #{invalid.keys}" if invalid.any?

      RETIREMENT_RESOLUTIONS
    end

    def outcome_counts(seller, cutoff_at, followers)
      counts = Hash.new(0)
      followers.where(followed_id: seller.id).in_batches(of: @batch_size) do |batch|
        rows = batch.to_a
        context = batch_context(seller, rows)
        rows.each { counts[classify(_1, cutoff_at, **context.merge(user: context[:users][_1.follower_user_id]))] += 1 }
      end
      counts.sort.to_h
    end

    def with_run_lock(seller)
      name = "feature_announcement_newsletter_cutover_#{seller.id}"
      connection = ApplicationRecord.connection
      acquired = connection.select_value(ApplicationRecord.sanitize_sql_array(["SELECT GET_LOCK(?, ?)", name, RUN_LOCK_TIMEOUT_SECONDS])).to_i == 1
      raise AlreadyRunning, "Another newsletter migration run holds #{name}" unless acquired

      begin
        yield
      ensure
        connection.select_value(ApplicationRecord.sanitize_sql_array(["SELECT RELEASE_LOCK(?)", name]))
      end
    end

    # Rechecks under share locks, user then follower (the order the gate and Settings use), that the
    # follow is still this seller's and linked to the locked account. A concurrent preference write is
    # caught by the unique key, and a buyer opt-out ends in Follower.unsubscribe, which waits on our lock.
    def migrate(seller, cutover, follower)
      return :skipped unless follower.follower_user_id && VERIFIED_SOURCES.key?(follower.source)

      ApplicationRecord.transaction do
        user = User.lock("FOR SHARE").find_by(id: follower.follower_user_id)
        current = Follower.lock("FOR SHARE").find_by(id: follower.id)
        next :changed_since_read unless user && current&.followed_id == seller.id && current.follower_user_id == user.id

        outcome = classify(current, cutover.cutoff_at, user:, **current_context(seller, current, user))
        next outcome unless outcome == :eligible

        FeatureAnnouncementSubscription.create!(user_id: user.id, subscribed: true, source: "newsletter_migration")
        FeatureAnnouncementNewsletterCutover.where(id: cutover.id)
          .update_all(["migrated_count = migrated_count + 1, cursor_follower_id = GREATEST(cursor_follower_id, ?), updated_at = ?", current.id, Time.current])
        :migrated
      end
    rescue ActiveRecord::RecordNotUnique
      :existing_preference
    end

    def current_context(seller, follower, user)
      email = normalize(follower.email)
      {
        shared_emails: User.where(email:).count > 1 ? Set[email] : Set.new,
        preference_user_ids: FeatureAnnouncementSubscription.where(user_id: user.id).exists? ? Set[user.id] : Set.new,
        opted_out_emails: Purchase.where(seller_id: seller.id, email:, can_contact: false).exists? ? Set[email] : Set.new,
      }
    end

    def batch_context(seller, followers)
      emails = followers.map { normalize(_1.email) }.uniq
      users = User.where(id: followers.filter_map(&:follower_user_id)).index_by(&:id)
      {
        users:,
        shared_emails: User.where(email: emails).group(:email).having("COUNT(*) > 1").count.keys.map { normalize(_1) }.to_set,
        preference_user_ids: FeatureAnnouncementSubscription.where(user_id: users.keys).pluck(:user_id).to_set,
        opted_out_emails: Purchase.where(seller_id: seller.id, email: emails, can_contact: false).distinct.pluck(:email).map { normalize(_1) }.to_set,
      }
    end

    def classify(follower, cutoff_at, user:, shared_emails:, preference_user_ids:, opted_out_emails:, **)
      return :follower_inactive unless follower.deleted_at.nil? && follower.confirmed_at.present?
      return :after_cutoff if follower.confirmed_at > cutoff_at || follower.created_at > cutoff_at
      return :unproven_source unless EXPRESS_SOURCES.include?(follower.source)
      return :guest if follower.follower_user_id.nil?
      return :unmatched_account if user.nil?
      return :inactive_account unless user.account_active?
      return :unconfirmed_account unless user.confirmed?
      return :conflicting_address unless user.email.present? && normalize(user.email) == normalize(follower.email)
      return :ambiguous_address if shared_emails.include?(normalize(follower.email))
      return :buyer_opted_out if opted_out_emails.include?(normalize(follower.email))
      return :existing_preference if preference_user_ids.include?(user.id)
      return :unverified_source unless VERIFIED_SOURCES.key?(follower.source)

      :eligible
    end

    def normalize(email) = email.to_s.strip.downcase
end
