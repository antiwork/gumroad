# frozen_string_literal: true

# Carries subscribers of Gumroad's own newsletter into Feature announcements, then retires the old
# newsletter (gumroad-private#3664). Run in order: preflight → prepare! → apply!(confirmed_eligible_count:)
# → retire!. Nothing runs on its own; apply! needs the eligible count from the stored plan.
#
# The baseline (A) is an active, confirmed follow at the cutoff, mapped to one active confirmed account
# (its recorded link, or the only confirmed account at that address) whose old announcement setting is on,
# with no buyer opt-out. Only A rows whose source cohort has a reviewed decision in VERIFIED_SOURCES and no
# existing preference are carried over; an existing preference row (including an opt-out) is never touched.
class Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements
  NEWSLETTER_SELLER_EXTERNAL_ID = "6282492303727"
  NEWSLETTER_SELLER_USERNAME = "gumroad"
  # Source labels describe how a row was added; none includes or excludes a cohort by its name alone.
  NO_SOURCE = "(none)"
  # Reviewed decisions to carry a source cohort over (label => decision reference). apply! refuses while empty.
  VERIFIED_SOURCES = {
    "embed_form" => "gumroad-private#3664: exclude signup-added follows (2026-10-19)",
    NO_SOURCE => "gumroad-private#3664: exclude signup-added follows (2026-10-19)",
    "manual-by-sahil" => "gumroad-private#3664: exclude signup-added follows (2026-10-19)",
    "csv_import" => "gumroad-private#3664: exclude signup-added follows (2026-10-19)",
    "profile_page" => "gumroad-private#3664: exclude signup-added follows (2026-10-19)",
    "follow_page" => "gumroad-private#3664: exclude signup-added follows (2026-10-19)",
    "product_page" => "gumroad-private#3664: exclude signup-added follows (2026-10-19)"
  }.freeze
  BASELINE_OUTCOMES = %i[eligible unverified_source existing_preference].freeze
  # Outcomes where retiring the old newsletter takes no mail anyone still wants.
  RESOLVED_OUTCOMES = %i[follower_inactive existing_preference buyer_opted_out].freeze
  # Reviewed decisions for any other cohort (outcome => decision reference); retire! refuses until all are covered.
  RETIREMENT_RESOLUTIONS = {}.freeze
  BATCH_SIZE = 1_000
  OPT_OUT_EMAILS_PER_QUERY = 100
  RUN_LOCK_TIMEOUT_SECONDS = 0

  class SourceUnverified < StandardError; end
  class InvalidTransition < StandardError; end
  class PlanMismatch < StandardError; end
  class AlreadyRunning < StandardError; end
  class CoverageIncomplete < StandardError; end
  class AmbientTransaction < StandardError; end
  class UnsupportedIsolation < StandardError; end

  def self.preflight(cutoff_at:, welcome_greeter_sources: nil, batch_size: BATCH_SIZE) = new(batch_size:).preflight(cutoff_at, welcome_greeter_sources:)
  def self.prepare!(cutoff_at:, batch_size: BATCH_SIZE) = new(batch_size:).prepare!(cutoff_at)
  def self.apply!(confirmed_eligible_count:, batch_size: BATCH_SIZE) = new(batch_size:).apply!(confirmed_eligible_count)
  def self.retire! = new.retire!
  def self.rollback!(batch_size: BATCH_SIZE) = new(batch_size:).rollback!

  def initialize(batch_size: BATCH_SIZE)
    @batch_size = batch_size
  end

  # Read-only: every follower of the newsletter seller, counted by outcome in one transaction, so every
  # batch reads the same snapshot. `baseline[:a]` is A; `baseline[:b]` is A without the declared
  # welcome-greeter source labels. Neither is permission: only `counts[:eligible]` can be applied.
  def preflight(cutoff_at, welcome_greeter_sources: nil)
    on_primary do
      ApplicationRecord.transaction do
        seller = verified_seller!
        read_at = Time.current
        tally = tally(seller, cutoff_at, Follower.all)
        { seller_id: seller.id, cutoff_at:, read_at:, verified_sources: verified_sources!, counts: tally[:counts],
          baseline: baseline(tally[:a], welcome_greeter_sources) }
      end
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
        # Waits out confirmations already holding the cutover row. One stamped before scan_started_at commits
        # before the scan reads; a later one is stamped at or after it, so the recheck below sees it.
        FeatureAnnouncementNewsletterCutover.transaction { FeatureAnnouncementNewsletterCutover.lock.find_by!(seller_id: seller.id) }
        counts = outcome_counts(seller, cutover.cutoff_at, Follower.all)
        coverage = nil
        transition!(seller, from: %w[migrated], to: "retired", retired_at: Time.current) do |locked|
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

    # The FOR UPDATE must be the transaction's first read: under REPEATABLE READ the first plain read
    # fixes the snapshot, and the block's recheck has to see follows confirmed while it waited.
    def transition!(seller, from:, to:, **attributes)
      FeatureAnnouncementNewsletterCutover.transaction do
        cutover = FeatureAnnouncementNewsletterCutover.lock.find_by!(seller_id: seller.id)
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
      invalid = VERIFIED_SOURCES.reject { |label, decision| label.is_a?(String) && label.present? && decision.present? }
      raise SourceUnverified, "Every verified source needs a label and a recorded decision: #{invalid.keys}" if invalid.any?

      VERIFIED_SOURCES
    end

    def retirement_resolutions!
      invalid = RETIREMENT_RESOLUTIONS.select { |outcome, decision| outcome == :eligible || decision.blank? }
      raise CoverageIncomplete, "Eligible subscribers must be migrated, and every resolution needs a decision: #{invalid.keys}" if invalid.any?

      RETIREMENT_RESOLUTIONS
    end

    def outcome_counts(seller, cutoff_at, followers) = tally(seller, cutoff_at, followers)[:counts]

    def tally(seller, cutoff_at, followers)
      counts = Hash.new(0)
      a = { total: 0, linked: 0, email_mapped: 0, existing_opt_in: 0, existing_opt_out: 0, by_source: Hash.new(0) }
      followers.where(followed_id: seller.id).in_batches(of: @batch_size) do |batch|
        rows = batch.to_a
        context = batch_context(seller, rows.reject { initial_outcome(_1, cutoff_at) })
        rows.each do |follower|
          identity = resolve_identity(follower, context[:users][follower.follower_user_id], context[:confirmed_by_email][normalize(follower.email)])
          outcome = classify(follower, cutoff_at, identity:, **context)
          counts[outcome] += 1
          next unless BASELINE_OUTCOMES.include?(outcome)

          a[:total] += 1
          a[follower.follower_user_id ? :linked : :email_mapped] += 1
          a[:by_source][source_label(follower)] += 1
          preference = context[:preferences][identity.id]
          a[preference ? :existing_opt_in : :existing_opt_out] += 1 unless preference.nil?
        end
      end
      { counts: counts.sort.to_h, a: a.merge(by_source: a[:by_source].sort.to_h) }
    end

    def baseline(a, welcome_greeter_sources)
      return { a:, b: nil, b_note: "welcome-greeter source labels not declared" } if welcome_greeter_sources.nil?

      excluded = a[:by_source].slice(*welcome_greeter_sources)
      { a:, welcome_greeter_sources:, b: { total: a[:total] - excluded.values.sum, excluded: } }
    end

    # An outer transaction would hold its old snapshot and swallow the per-row commits, so refuse one. Writers
    # order against the cutover through gap locks (FeatureAnnouncementNewsletterCutover.locked_state), which
    # only REPEATABLE READ takes.
    def with_run_lock(seller)
      raise AmbientTransaction, "Run the newsletter cutover outside a transaction" if ApplicationRecord.connection.current_transaction.joinable?
      isolation = ApplicationRecord.connection.select_rows("SELECT @@SESSION.transaction_isolation, @@GLOBAL.transaction_isolation").first
      raise UnsupportedIsolation, "The newsletter cutover needs REPEATABLE READ, not #{isolation.uniq.join("/")}" unless isolation.all?("REPEATABLE-READ")

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

    # Locks users before the follower (the order the gate and Settings use), then rechecks everything: the
    # follow is still this seller's with the same link and address, and the address still has one confirmed
    # account. Locking every confirmed account at the address keeps another from being confirmed there until
    # this commits. A copy then locks the cutover row before the preference, as every writer does. A concurrent
    # preference write is caught by the unique key, and a buyer opt-out ends in Follower.unsubscribe, which
    # waits on the follower lock.
    def migrate(seller, cutover, follower)
      return :skipped unless VERIFIED_SOURCES.key?(source_label(follower))

      conflicts ||= 0
      email = normalize(follower.email)
      ApplicationRecord.transaction do
        linked = follower.follower_user_id && User.lock("FOR SHARE").find_by(id: follower.follower_user_id)
        confirmed = User.where(email:).where.not(confirmed_at: nil).lock("FOR SHARE").to_a
        # An email-mapped follow is bound to its account below, so take the row for writing now.
        current = Follower.lock(follower.follower_user_id ? "FOR SHARE" : "FOR UPDATE").find_by(id: follower.id)
        unchanged = current && current.followed_id == seller.id && current.follower_user_id == follower.follower_user_id && normalize(current.email) == email
        next :changed_since_read unless unchanged

        identity = resolve_identity(current, linked, confirmed)
        context = current_context(seller, current, identity)
        outcome = classify(current, cutover.cutoff_at, identity:, **context)
        # Recording the link keeps every old-newsletter opt-out path pointed at this account, even after its
        # email changes. An account that already chose has its choice left exactly as it is.
        if current.follower_user_id.nil? && (outcome == :eligible || chose_already?(current, cutover.cutoff_at, identity, context[:preferences]))
          current.update_columns(follower_user_id: identity.id)
        end
        next outcome unless outcome == :eligible

        # The cutover row before the preference, the order an opt-out uses when it locks the row first, so the
        # two queue on the row instead of each holding what the other waits for.
        FeatureAnnouncementNewsletterCutover.where(id: cutover.id).lock.pick(:id)
        FeatureAnnouncementSubscription.create!(user_id: identity.id, subscribed: true, source: "newsletter_migration")
        FeatureAnnouncementNewsletterCutover.where(id: cutover.id)
          .update_all(["migrated_count = migrated_count + 1, cursor_follower_id = GREATEST(cursor_follower_id, ?), updated_at = ?", current.id, Time.current])
        :migrated
      end
    rescue ActiveRecord::RecordNotUnique
      # A preference written since the check took the unique key and rolled the link back with this row; the
      # second pass sees it as existing and records only the link.
      retry if (conflicts += 1) == 1
      :existing_preference
    end

    # The account a follow maps to, or why it maps to none. A recorded link is never reassigned.
    def resolve_identity(follower, linked, confirmed)
      confirmed ||= []
      if follower.follower_user_id
        return :unmatched_account if linked.nil?
        return :conflicting_address unless linked.email.present? && normalize(linked.email) == normalize(follower.email)
        return :ambiguous_address if confirmed.any? { _1.id != linked.id }

        linked
      else
        return :guest if confirmed.empty?
        return :ambiguous_address if confirmed.many?

        confirmed.first
      end
    end

    def current_context(seller, follower, identity)
      email = normalize(follower.email)
      preference = identity.is_a?(User) ? FeatureAnnouncementSubscription.where(user_id: identity.id).pick(:subscribed) : nil
      {
        preferences: preference.nil? ? {} : { identity.id => preference },
        opted_out_emails: Purchase.where(seller_id: seller.id, email:, can_contact: false).exists? ? Set[email] : Set.new,
      }
    end

    def batch_context(seller, followers)
      emails = followers.map { normalize(_1.email) }.uniq
      users = User.where(id: followers.filter_map(&:follower_user_id)).index_by(&:id)
      confirmed_by_email = User.where(email: emails).where.not(confirmed_at: nil).to_a.group_by { normalize(_1.email) }
      user_ids = users.keys | confirmed_by_email.values.flatten.map(&:id)
      {
        users:,
        confirmed_by_email:,
        preferences: FeatureAnnouncementSubscription.where(user_id: user_ids).pluck(:user_id, :subscribed).to_h,
        opted_out_emails: opted_out_emails(seller, emails),
      }
    end

    def opted_out_emails(seller, emails)
      emails.each_slice(OPT_OUT_EMAILS_PER_QUERY).flat_map do |batch|
        Purchase.where(seller_id: seller.id, email: batch, can_contact: false).distinct.pluck(:email)
      end.map { normalize(_1) }.to_set
    end

    def initial_outcome(follower, cutoff_at)
      return :follower_inactive unless follower.deleted_at.nil? && follower.confirmed_at.present?
      return :after_cutoff if follower.confirmed_at > cutoff_at || follower.created_at > cutoff_at

      nil
    end

    def classify(follower, cutoff_at, identity:, preferences:, opted_out_emails:, **)
      outcome = initial_outcome(follower, cutoff_at)
      return outcome if outcome

      return identity if identity.is_a?(Symbol)
      return :inactive_account unless identity.account_active?
      return :unconfirmed_account unless identity.confirmed?
      # Read from the locked row when applying, so turning it off before the copy is honored.
      return :announcements_off unless identity.announcement_notification_enabled
      return :buyer_opted_out if opted_out_emails.include?(normalize(follower.email))
      return :existing_preference if preferences.key?(identity.id)
      return :unverified_source unless VERIFIED_SOURCES.key?(source_label(follower))

      :eligible
    end

    # Decided apart from classify: the old announcement setting and a buyer opt-out keep an account out of A,
    # but its existing choice still needs the link, so a later old-newsletter opt-out reaches it.
    def chose_already?(follower, cutoff_at, identity, preferences)
      identity.is_a?(User) && preferences.key?(identity.id) && follower.deleted_at.nil? && follower.confirmed_at.present? &&
        follower.confirmed_at <= cutoff_at && follower.created_at <= cutoff_at && identity.account_active? && identity.confirmed?
    end

    def source_label(follower) = follower.source.presence || NO_SOURCE

    def normalize(email) = email.to_s.strip.downcase
end
