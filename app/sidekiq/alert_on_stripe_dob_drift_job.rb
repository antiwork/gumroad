# frozen_string_literal: true

# Reports sellers whose live `UserComplianceInfo#birthday` no longer agrees with the `individual.dob`
# their Gumroad-managed Stripe account holds (gumroad-private#1726).
#
# The two copies drive different live decisions and neither reads the other: the under-18 payout gate
# reads ours, Stripe's identity verification reads theirs. So a correction that never propagated is
# invisible until someone reads both side by side — which is how the reported case surfaced, on a
# support ticket about something else. Nothing today detects it.
#
# Reports only. Which of the two dates is true is exactly what a drift row leaves unestablished, so
# writing a date of birth onto a KYC record is a human decision in either direction.
class AlertOnStripeDobDriftJob
  include Sidekiq::Job
  include RecurringLockTtl

  # Serialized: the Redis cursor is read, used, and written back in separate steps, so two overlapping
  # runs would claim the same page, spend the Stripe budget twice and send the report twice.
  sidekiq_options retry: 2, queue: :low, lock: :until_executed
  # Worst case is the read budget, not the database: MAX_CANDIDATES_SCANNED sequential
  # `Stripe::Account.retrieve` calls. At a pessimistic ~2s each — a Stripe timeout rather than a
  # normal round trip — 400 accounts is ~13 minutes, so 30 gives the budget room to grow without
  # the declaration going stale silently.
  recurring_lock_ttl max_attempt: 30.minutes

  # Report at most this many. The alert exists to be read.
  MAX_REPORTED = 25

  # The bound on the work: how many accounts get a Stripe read per run. Each candidate costs one
  # `Stripe::Account.retrieve`, so this is a rate budget, not a database one. Successive runs resume
  # from a saved cursor and wrap, so the population is covered across runs rather than the same page
  # being re-read forever.
  MAX_CANDIDATES_SCANNED = 400

  def perform
    scan = scan_for_drift
    # Nothing qualifying is only silence when the run actually established that. A truncated scan
    # means the bound decided the report was empty, and unreadable accounts mean Stripe did — both
    # are results, and neither is evidence the platform is clean.
    return if scan[:drifted].empty? && !scan[:truncated] && scan[:unreadable].zero?

    InternalNotificationWorker.perform_async("payouts", "Stripe date-of-birth drift", message_for(scan))
  end

  private
    def scan_for_drift
      after_id = current_cursor
      candidates = candidate_accounts(after_id)

      # Exhausted the population: wrap to the beginning so the sweep is a loop rather than a dead end.
      if candidates.empty? && after_id.positive?
        save_cursor(0)
        candidates = candidate_accounts(0)
      end

      truncated = candidates.size > MAX_CANDIDATES_SCANNED
      candidates = candidates.first(MAX_CANDIDATES_SCANNED)
      # Advance past what this run judged, before the Stripe reads, so a later failure cannot pin the
      # cursor and re-scan the same page forever.
      save_cursor(candidates.last.id) if candidates.any?

      drifted = []
      unreadable = 0

      candidates.each do |merchant_account|
        # The model's own predicate rather than a SQL rewrite of it, the same way
        # AlertOnNegativeDestinationBalancesJob does: a Stripe Connect account's legal entity is the
        # seller's own to maintain, we push nothing onto it, and a hand-written
        # `json_data->>'$.meta.stripe_connect'` filter is a second copy of a rule that already exists.
        next unless merchant_account.is_a_gumroad_managed_stripe_account?

        user = merchant_account.user
        next if user.nil?

        compliance_info = user.alive_user_compliance_info
        next if compliance_info.nil?
        # A business account's date of birth belongs to its representative and is synced through
        # `update_person`, not `individual`, so comparing it against `individual.dob` would report
        # every one of them.
        next unless compliance_info.is_individual?

        ours = compliance_info.birthday
        next if ours.blank?

        theirs = stripe_dob(merchant_account)
        if theirs == :unreadable
          unreadable += 1
          next
        end
        next if theirs == ours

        drifted << {
          user:,
          merchant_account:,
          ours:,
          theirs:,
          compliance_info_id: compliance_info.id,
        }
      end

      { drifted: report_order(drifted), unreadable:, truncated: }
    end

    # Live Stripe merchant accounts we manage the legal entity on, oldest id first, one over the
    # budget so that exhausting the population is distinguishable from it holding exactly that many.
    #
    # Connect accounts are excluded here via the model's own `stripe_connect` scope rather than a
    # hand-written `json_data->>` predicate, so there is still one definition of that rule. Excluding
    # them in SQL rather than only in the loop matters for the BUDGET: filtered in Ruby, a page that
    # happens to start with 400 Connect rows would spend the whole budget, advance the cursor past
    # them, and report no drift without having read a single managed account. The loop keeps the
    # model predicate as the authority anyway.
    #
    # Ordered by id rather than by anything drift-related because the ordering IS the resume cursor,
    # and no column records when the two copies last agreed.
    def candidate_accounts(after_id)
      MerchantAccount.alive
                     .charge_processor_alive
                     .stripe
                     .where.not(user_id: nil)
                     .where("merchant_accounts.id > ?", after_id)
                     .where.not(id: MerchantAccount.stripe_connect.select(:id))
                     .order(id: :asc)
                     .limit(MAX_CANDIDATES_SCANNED + 1)
                     .to_a
    end

    def current_cursor
      $redis.get(RedisKey.stripe_dob_drift_sweep_cursor).to_i
    rescue => e
      # A lost cursor re-scans the first page, which costs Stripe reads but reports the truth.
      # Losing the run is worse.
      ErrorNotifier.notify(e)
      0
    end

    def save_cursor(cursor_id)
      $redis.set(RedisKey.stripe_dob_drift_sweep_cursor, cursor_id)
    rescue => e
      ErrorNotifier.notify(e)
    end

    # Stripe's copy as a Date, `nil` when the account holds no date of birth, or `:unreadable` when
    # the read itself failed. The three are deliberately distinct: a missing dob on Stripe IS drift
    # against a birthday we hold, while a failed read establishes nothing and must not be reported as
    # agreement or as drift.
    #
    # Read with `[]` rather than `dig`: `Stripe::Account` is a `Stripe::StripeObject`, which does not
    # implement `dig` at all (it wraps a values hash and exposes `[]`), so `dig` raises NoMethodError
    # on every account. A stubbed plain Hash in a spec hides that, because Hash does implement it.
    def stripe_dob(merchant_account)
      account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
      individual = account["individual"]
      dob = individual && individual["dob"]
      return nil if dob.nil?

      year, month, day = dob["year"], dob["month"], dob["day"]
      return nil if year.blank? || month.blank? || day.blank?

      Date.new(year.to_i, month.to_i, day.to_i)
    rescue Date::Error
      # A partial or impossible date on Stripe's side is not something this report can resolve into a
      # comparison, and it is not a read failure either.
      nil
    rescue Stripe::StripeError => e
      Rails.logger.warn "Could not read the Stripe date of birth for merchant account #{merchant_account.id}: #{e.class}: #{e.message}"
      :unreadable
    end

    def message_for(scan)
      drifted = scan[:drifted]
      lines = drifted.first(MAX_REPORTED).map { |entry| line_for(entry) }
      omitted = drifted.size - lines.size

      [
        headline(drifted.size, scan[:truncated], scan[:unreadable]),
        (scan[:truncated] ? "The scan stopped at #{MAX_CANDIDATES_SCANNED} accounts, so this is a floor — the population is larger than the count above." : nil),
        (scan[:unreadable].positive? ? "#{scan[:unreadable]} more could not be read from Stripe this run, so they are neither clear nor drifted." : nil),
        "",
        *lines,
        (omitted.positive? ? "…and #{omitted} more." : nil),
        "",
        "The two copies drive different decisions: the under-18 payout gate reads ours, Stripe's " \
          "identity verification reads theirs. A younger date on our side holds payouts while " \
          "Stripe runs an adult records check that cannot match; an older date on our side means " \
          "the gate does not engage for someone Stripe holds as a minor. " \
          "Do not correct either copy from this report — which date is true is what a line here " \
          "leaves open, and the seller's own later revision is evidence, not proof. " \
          "See gumroad-private#1726.",
      ].compact.join("\n")
    end

    # Under-18-on-our-side first, then widest gap first. What ranks a line is whether money is
    # already being held on the strength of the disagreement.
    def report_order(drifted)
      drifted.sort_by do |entry|
        gap = entry[:theirs] ? (entry[:theirs] - entry[:ours]).to_i.abs : Float::INFINITY
        [entry[:ours] > UserComplianceInfo::GUARDIAN_REQUIRED_BELOW_AGE.years.ago.to_date ? 0 : 1, -gap]
      end
    end

    def line_for(entry)
      theirs = entry[:theirs] || "no date of birth on file"
      gated = entry[:ours] > UserComplianceInfo::GUARDIAN_REQUIRED_BELOW_AGE.years.ago.to_date ? " [under 18 on our side — payouts gated]" : ""
      "• #{entry[:user].email} (user #{entry[:user].id}) — we hold #{entry[:ours]}, Stripe holds #{theirs} " \
        "on #{entry[:merchant_account].charge_processor_merchant_id}#{gated}, " \
        "live compliance record #{entry[:compliance_info_id]}"
    end

    def headline(count, truncated, unreadable)
      if count.zero?
        # Name the reason the page came back empty, because "none found" and "none established" are
        # different facts and only one of them is reassuring.
        reason = if truncated && unreadable.positive?
          "but the scan was truncated and #{unreadable} account#{"s" if unreadable != 1} could not be read"
        elsif truncated
          "but the scan was truncated"
        else
          "but #{unreadable} account#{"s" if unreadable != 1} could not be read"
        end
        return "No live Gumroad-managed Stripe account on the scanned page disagrees with our date of birth, #{reason}, so this is not evidence that none do."
      end

      "#{truncated ? "At least " : ""}#{count} seller#{"s" if count != 1} " \
        "#{count == 1 ? "has" : "have"} a date of birth on Stripe that disagrees with ours."
    end
end
