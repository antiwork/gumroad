# frozen_string_literal: true

# Pre-charge signal for card-testing cash-out rings: the daily chargeback-ring scan could only
# pause payouts after a ring's sales had already been charged.
#
# The country-dominance and hosting-IP clauses only mean anything together: young legitimate
# sellers whose buyers share one country are common, and a datacenter block is what separates a
# mill from them.
#
# Two Flipper flags, both default off (Flipper booleans can't express a three-level flag):
#   - chargeback_ring_signal         evaluate + telemetry + payout pause + fraud flag + ops alert
#                                    (shadow: no buyer is ever refused)
#   - chargeback_ring_signal_enforce additionally refuse the charge, but ONLY when the in-flight
#                                    purchase itself carries the ring evidence: its ip_address is
#                                    inside the matched hosting CIDR AND its card_country is the
#                                    dominant country. A buyer on a normal IP is never refused.
#
# With chargeback_ring_signal off, evaluate is never called — zero behaviour change.
# Fail-open throughout: an exception allows the purchase and records an `error` row.
module Purchase::ChargebackRingSignal
  FEATURE_FLAG = :chargeback_ring_signal
  ENFORCE_FLAG = :chargeback_ring_signal_enforce

  MIN_PAID_SALES = 3
  DOMINANT_CARD_COUNTRY_SHARE_PCT = 90.0
  HOSTING_IP_SHARE_PCT = 80.0
  MAX_SELLER_AGE_DAYS = 120
  WINDOW = 30.days
  # Hard bound on rows read per evaluation; the age clause restricts evaluation to accounts
  # younger than 120 days, so this is generous slack for the biggest plausible young seller.
  SAMPLE_LIMIT = 2_000
  # A multi-item cart evaluates once per purchase; the seller's 30-day aggregate can't
  # meaningfully change inside a minute, so one query serves the whole cart (and burst traffic).
  CACHE_TTL = 1.minute

  # Hosting/datacenter blocks as data: a new ring's block is a one-line addition.
  # 151.240.0.0/16: measured 2026-11 from the two production card mills (sellers 28262165 and
  # 28522244) — the /16 their checkout traffic came from. Not a general hosting detector; blocks
  # are added here as rings are measured.
  HOSTING_CIDR_STRINGS = %w[
    151.240.0.0/16
  ].freeze
  HOSTING_CIDRS = HOSTING_CIDR_STRINGS.map { IPAddr.new(_1) }.freeze

  DECISION_BLOCKED = "blocked"
  DECISION_ALLOWED = "allowed"
  DECISION_ERROR = "error"

  # decision is the RULE's verdict on the seller's existing sales; whether any buyer was actually
  # refused additionally depends on the enforce flag and on buyer-level evidence at charge time.
  Result = Struct.new(
    :decision,
    :paid_sales,
    :dominant_card_country,
    :dominant_share_pct,
    :hosting_share_pct,
    :distinct_browsers,
    :matched_cidr,
    keyword_init: true
  ) do
    def hit? = decision == DECISION_BLOCKED
    def error? = decision == DECISION_ERROR

    # Both sides (blocked and allowed) are recorded once the volume clause is reached, so the
    # false-positive rate is measurable. Error rows always record.
    def recordable? = error? || (paid_sales.present? && paid_sales >= MIN_PAID_SALES)
  end

  class << self
    # The age clause is decided before any query, so the bounded sample below is only ever read
    # for accounts young enough to be candidates.
    def evaluate(seller:)
      if seller.created_at <= MAX_SELLER_AGE_DAYS.days.ago
        return Result.new(decision: DECISION_ALLOWED)
      end

      Rails.cache.fetch("chargeback_ring_signal/v1/#{seller.id}", expires_in: CACHE_TTL) do
        evaluate_uncached(seller:)
      end
    end

    def evaluate_uncached(seller:)
      rows = Purchase.where(seller_id: seller.id, purchase_state: "successful")
                     .where("price_cents > 0")
                     .where(created_at: WINDOW.ago..)
                     .limit(SAMPLE_LIMIT)
                     .pluck(:card_country, :ip_address, :browser_guid)

      paid_sales = rows.size
      country_counts = rows.map(&:first).compact.tally
      dominant_card_country, dominant_count = country_counts.max_by { |_country, count| count }
      # nil card_country rows stay in the denominator: unknowns lower the share, which allows.
      dominant_share_pct = paid_sales.zero? ? 0.0 : (100.0 * dominant_count.to_i / paid_sales).round(2)

      cidr_hits = Hash.new(0)
      rows.each do |_country, ip, _guid|
        cidr = matching_cidr(ip)
        cidr_hits[cidr] += 1 if cidr
      end
      hosting_count = cidr_hits.values.sum
      hosting_share_pct = paid_sales.zero? ? 0.0 : (100.0 * hosting_count / paid_sales).round(2)
      matched_cidr = cidr_hits.max_by { |_cidr, count| count }&.first

      distinct_browsers = rows.map(&:last).compact.uniq.size

      blocked = paid_sales >= MIN_PAID_SALES &&
        dominant_share_pct >= DOMINANT_CARD_COUNTRY_SHARE_PCT &&
        hosting_share_pct >= HOSTING_IP_SHARE_PCT

      Result.new(
        decision: blocked ? DECISION_BLOCKED : DECISION_ALLOWED,
        paid_sales:,
        dominant_card_country:,
        dominant_share_pct:,
        hosting_share_pct:,
        distinct_browsers:,
        matched_cidr:
      )
    end

    def matching_cidr(ip)
      return nil if ip.blank?

      parsed = begin
        IPAddr.new(ip)
      rescue IPAddr::InvalidAddressError, ArgumentError
        # An unparseable stored IP counts as non-hosting: lowers the share, allows the sale.
        return nil
      end
      index = HOSTING_CIDRS.index { _1.include?(parsed) }
      index && HOSTING_CIDR_STRINGS[index]
    end

    # ErrorNotifier must never be the reason a purchase or its containment fails.
    def safe_notify(*args, **kwargs)
      ErrorNotifier.notify(*args, **kwargs)
    rescue StandardError
      nil
    end
  end

  private
    # before_create in Purchase, right after check_for_fraud. Evaluation only — it never refuses:
    # refusal (if the enforce flag is on AND this purchase carries buyer-level evidence) happens
    # in refuse_charge_for_chargeback_ring_signal? at charge time, where card_country is known.
    def evaluate_chargeback_ring_signal
      return if errors.present?
      return unless chargeback_ring_signal_applicable?

      @chargeback_ring_signal_result = Purchase::ChargebackRingSignal.evaluate(seller:)
      nil
    rescue StandardError => e
      @chargeback_ring_signal_result = Purchase::ChargebackRingSignal::Result.new(
        decision: Purchase::ChargebackRingSignal::DECISION_ERROR
      )
      Purchase::ChargebackRingSignal.safe_notify(e, seller_id: seller&.id)
      nil
    end

    def chargeback_ring_signal_applicable?
      return false if seller.nil?
      return false if free_purchase?
      # Renewals aren't new ring sales — same carve-out as check_for_past_fraudulent_ips.
      return false if is_recurring_subscription_charge

      Feature.active?(Purchase::ChargebackRingSignal::FEATURE_FLAG, seller)
    end

    # A purchase loaded in a later request (the India-mandate resume in Order::ConfirmService)
    # never ran the before_create, so evaluate on first read. Its create commit has already
    # passed, so record (telemetry + containment) once the current transaction commits: the
    # resume refuses inside a purchase lock, and the seller's hold must not depend on it.
    def chargeback_ring_signal_result
      return @chargeback_ring_signal_result if defined?(@chargeback_ring_signal_result)
      return @chargeback_ring_signal_result = nil unless chargeback_ring_signal_applicable?

      @chargeback_ring_signal_result = begin
        Purchase::ChargebackRingSignal.evaluate(seller:)
      rescue StandardError => e
        Purchase::ChargebackRingSignal.safe_notify(e, purchase_id: id, seller_id: seller&.id)
        Purchase::ChargebackRingSignal::Result.new(decision: Purchase::ChargebackRingSignal::DECISION_ERROR)
      end
      after_commit { record_chargeback_ring_signal } if persisted?
      @chargeback_ring_signal_result
    end

  public

    # Called before any processor call — at the top of Purchase#charge! for single purchases,
    # from Charge::CreateService#perform for combined (cart) charges, and from
    # Order::PreparePaymentIntentService before a client-confirm intent exists — so a refusal
    # provably never reaches the processor. Public because those services invoke it per purchase.
    # Refuses only on buyer-level evidence: this purchase's IP inside the matched hosting CIDR
    # AND its card country equal to the dominant one. The containment (payout pause, fraud flag,
    # alert) does not depend on this refusal.
    def refuse_charge_for_chargeback_ring_signal?
      # Enforce first: in shadow mode a reloaded purchase must not trigger the lazy evaluation.
      return false unless Feature.active?(Purchase::ChargebackRingSignal::ENFORCE_FLAG, seller)
      result = chargeback_ring_signal_result
      return false unless result&.hit?
      return false if result.matched_cidr.nil? || result.dominant_card_country.nil?
      return false unless Purchase::ChargebackRingSignal.matching_cidr(ip_address) == result.matched_cidr
      return false unless card_country.present? && card_country == result.dominant_card_country

      # Compute the message before assigning any refusal state, so the rescue below never has
      # partially-applied state to undo beyond error_code.
      message = vague_error_message
      self.error_code = PurchaseErrorCode::CHARGEBACK_RING_SIGNAL
      # Generic, non-accusatory refusal — same wording as the sibling risk checks.
      errors.add :base, message
      true
    rescue StandardError => e
      # Fail-open; undo the refusal state so a bug here can't fail a legitimate sale.
      self.error_code = nil if error_code == PurchaseErrorCode::CHARGEBACK_RING_SIGNAL
      Purchase::ChargebackRingSignal.safe_notify(e, purchase_id: id, seller_id: seller&.id)
      false
    end

  private
    # after_commit on: :create, or after the commit that follows a lazy evaluation. Containment is
    # durable and runs FIRST; telemetry and the ops alert are best-effort. Each step is isolated so
    # none can take the others down, and nothing here can surface as a purchase failure.
    def record_chargeback_ring_signal
      result = @chargeback_ring_signal_result
      return if result.nil?
      return unless result.recordable?
      # A lazy read before this purchase's own create commit schedules both callbacks.
      return if @chargeback_ring_signal_recorded
      @chargeback_ring_signal_recorded = true

      if result.hit?
        begin
          contain_chargeback_ring_seller!(result)
        rescue StandardError => e
          Purchase::ChargebackRingSignal.safe_notify(e, purchase_id: id, seller_id:)
        end
      end

      begin
        ::ChargebackRingSignal.create!(
          seller_id:,
          purchase_id: id,
          decision: result.decision,
          paid_sales: result.paid_sales,
          dominant_card_country: result.dominant_card_country,
          dominant_share_pct: result.dominant_share_pct,
          hosting_share_pct: result.hosting_share_pct,
          distinct_browsers: result.distinct_browsers,
          matched_cidr: result.matched_cidr
        )
      rescue StandardError => e
        Purchase::ChargebackRingSignal.safe_notify(e, purchase_id: id, seller_id:)
      end

      if result.hit?
        Purchase::ChargebackRingSignal.safe_notify(
          "chargeback_ring_signal hit: seller_id=#{seller_id} paid_sales=#{result.paid_sales} " \
          "dominant=#{result.dominant_card_country} #{result.dominant_share_pct}% " \
          "hosting=#{result.hosting_share_pct}% cidr=#{result.matched_cidr}"
        )
      end
    end

    # Payout pause + fraud-review flag. No suspension: a human decides the account's fate.
    #
    # A human's decision is final: once someone released this hold or moved the account's risk
    # state after it was applied, a later sale must not contain the seller again. A hit stays a
    # hit for the whole 30-day window, so without this the release would be undone seconds after
    # the seller's next sale and shadow mode could not be run with a human in the loop.
    # Each step re-checks that decision INSIDE its own seller lock (see the two methods below): an
    # admin can release the hold between the read and the write, and containment must neither undo
    # a release that landed first nor leave a fresher ring comment behind — a newer ring comment
    # would make the admin's release read as older and re-arm containment on the next sale.
    def contain_chargeback_ring_seller!(result)
      pause_seller_payouts_for_ring_signal!(result)
      flag_seller_for_ring_review!
    end

    # True when a human released the hold or moved the risk state after the ring last contained
    # this seller. Always called INSIDE the seller lock (see the two steps above), so a release
    # that committed before the lock was taken is visible and wins.
    # Both write a comment carrying the acting admin's `author_id`; the automated
    # siblings write `author_name` only, and the ring's own pause/flag comments carry no
    # author_id either (`flag_for_fraud!` is called with `author_name:`), so an actor id after the
    # ring's containment comment is a human decision — whether it came from the admin console's
    # payouts resume or from a risk-state transition (`mark_compliant`, `put_on_probation`, ...).
    def human_decided_after_ring_containment?
      ring_author = User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:chargeback_ring_signal]
      # FLAGGED too: over an admin pause the pause step is skipped, so the fraud flag is the
      # ring's only containment record.
      ring_containment = seller.comments
        .where(comment_type: [Comment::COMMENT_TYPE_ON_PROBATION, Comment::COMMENT_TYPE_FLAGGED])
        .where(author_name: ring_author)
        .order(:id)
        .last
      return false if ring_containment.nil?

      human_comment_types = Comment::RISK_STATE_COMMENT_TYPES + [Comment::COMMENT_TYPE_PAYOUTS_RESUMED]
      # Compared by id, not created_at: `comments.created_at` is whole-second on this schema, so
      # a human's comment in the same second as the ring's would otherwise read as earlier.
      seller.comments
        .where(comment_type: human_comment_types)
        .where.not(author_id: nil)
        .where("id > ?", ring_containment.id)
        .exists?
    end

    # The repo's risk-review surface: flagged_for_fraud is the state the review queue reads (the
    # same mechanism Purchase::Blockable uses). Check-and-transition inside the seller lock with
    # a fresh read: can_flag_for_fraud? on a stale in-memory user could otherwise overwrite a
    # suspension that landed concurrently (flag_for_fraud transitions FROM suspended states are
    # already impossible, but only if the state it reads is current).
    def flag_seller_for_ring_review!
      seller.with_lock do
        next if human_decided_after_ring_containment?
        seller.reload
        # not_verified? halts the transition, so flag_for_fraud! would raise on every hit.
        next if seller.verified? || !seller.can_flag_for_fraud?

        seller.flag_for_fraud!(author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:chargeback_ring_signal])
      end
    end

    # Same pause mechanism as the existing chargeback-rate gate
    # (Purchase::Blockable#pause_payouts_for_seller_based_on_chargeback_rate!): the internal
    # system pause flag plus an on-probation comment, with the same locked re-check discipline.
    #
    # The ring comment landing LAST is what makes the containment hold:
    # User#payouts_paused_for_chargeback_rate? reads the newest pausing comment, and a ring
    # seller's measured rate is still low when the signal fires, so a hold that still reads as
    # the chargeback-rate one would be auto-released by ReleaseChargebackRatePayoutPausesJob.
    # An existing automatic hold therefore must NOT short-circuit this — the ring comment is
    # recorded on top of it. Only a human's own (admin) pause is left untouched.
    def pause_seller_payouts_for_ring_signal!(result)
      return if seller.payouts_paused_by_source == User::PAYOUT_PAUSE_SOURCE_ADMIN

      seller.with_lock do
        next if seller.payouts_paused_by_source == User::PAYOUT_PAUSE_SOURCE_ADMIN
        # A human who released this hold by hand keeps it released — checked under the lock, so a
        # release that committed before we took the lock wins and we add no ring comment after it.
        next if human_decided_after_ring_containment?
        # Idempotence: once the ring's own comment is the newest, a second hit adds nothing.
        next if seller.payouts_paused_for_chargeback_ring_signal?

        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
        seller.comments.create!(
          content: "Payouts automatically paused by the checkout chargeback-ring signal: " \
            "#{result.paid_sales} paid sales in #{Purchase::ChargebackRingSignal::WINDOW.inspect}, " \
            "#{result.dominant_share_pct}% from #{result.dominant_card_country}, " \
            "#{result.hosting_share_pct}% from hosting block #{result.matched_cidr}, " \
            "#{result.distinct_browsers} distinct browsers.",
          comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
          author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:chargeback_ring_signal]
        )
      end
    end
end
