# frozen_string_literal: true

module User::Risk
  extend ActiveSupport::Concern

  # Raised when something tries to clear a suspension without saying it means to.
  # See #refuse_unauthorized_suspension_clear.
  class SuspensionClearNotAuthorizedError < StandardError; end

  PAYMENT_REMINDER_RISK_STATES = %w[flagged_for_tos_violation not_reviewed compliant].freeze
  SUSPENDED_STATES = %w[suspended_for_tos_violation suspended_for_fraud].freeze
  INCREMENTAL_ENQUEUE_BALANCE = 100_00
  PROBATION_WITH_REMINDER_DAYS = 30
  PROBATION_REVIEW_DAYS = 2
  # Above this share of lifetime unrefunded sales volume lost to standing chargebacks, we hold the
  # seller's payouts automatically. 1% is the rate card networks treat as the healthy ceiling — Visa
  # and Mastercard both start monitoring a merchant around there — so it is the number we actually
  # want sellers to stay under, and holding at 3% meant a seller could sit at triple the healthy
  # rate indefinitely with payouts flowing.
  #
  # This is the same 1% used for automatic refund-policy enforcement below, but measured
  # differently: this one is a share of DOLLAR VOLUME, that one is a share of unique BUYERS.
  #
  # 1.5% over a trailing year, rather than 1% over lifetime (2026-08-03, Sahil). The old pairing
  # made the hold hard to exit on exactly the accounts most worth keeping: measured over lifetime,
  # a four-year seller's denominator is so large that a clean quarter barely moves the ratio, so a
  # seller who has already fixed the behaviour stays paused on history they cannot change. A
  # trailing window lets recent selling actually count, and the threshold moves up with it so the
  # change is a genuine loosening rather than a reshuffle.
  MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS = 1.5
  # 25% rolling reserve while the chargeback-volume pause is on (Terms 11.3(b) fraction).
  # Feature `:disable_chargeback_rate_payout_reserve` restores the old 100% skip.
  CHARGEBACK_RATE_PAYOUT_RESERVE_PERCENT = 25

  # Only sales inside this trailing window count toward the payout gate's chargeback rate. Keep the
  # pause and the release measuring the identical window — a release that reads a different span
  # than the pause either re-pauses immediately or never fires.
  PAYOUT_CHARGEBACK_RATE_WINDOW = 365.days

  # Thresholds for automatically forcing a buyer-friendly refund policy on a seller.
  # The dispute rate here is a rate of UNIQUE BUYERS (buyers with a standing chargeback /
  # buyers with settled purchases), not raw purchase counts and not dollar volume. It answers
  # "what share of your customers dispute you?" — so one unhappy buyer who disputes both
  # installments of the same course still counts once. Counting raw purchases previously let
  # a single buyer's two installment disputes tip a ~250-sale seller over the line (#6171).
  MAX_DISPUTE_COUNT_RATE_ALLOWED_FOR_CUSTOM_REFUND_POLICY = 1.0
  # Volume gates so a single unlucky dispute on a brand-new account doesn't trigger
  # enforcement. The settled-purchases gate stays purchase-based (it measures sales volume);
  # the disputes gate counts distinct disputing buyers (it measures how many separate
  # customers went to their bank).
  MIN_SETTLED_PURCHASES_FOR_REFUND_POLICY_ENFORCEMENT = 25
  MIN_DISPUTING_BUYERS_FOR_REFUND_POLICY_ENFORCEMENT = 3
  # When enforcement bumps a "No refunds allowed" policy, this is the period it becomes.
  ENFORCED_MIN_REFUND_PERIOD_IN_DAYS = 30

  REFUND_POLICY_ENFORCEMENT_COMMENT_AUTHOR = "enforce_refund_policy_for_seller_based_on_dispute_rate"

  # Lifetime dispute stats by UNIQUE BUYER (not raw purchases, not dollar volume). Used to
  # decide whether to auto-enforce a buyer-friendly refund policy on the seller — see
  # Purchase::Blockable#enforce_refund_policy_for_seller_based_on_dispute_rate!.
  #
  # Buyers are keyed by the purchase email, which exists on every purchase (guest checkouts
  # included), so a buyer disputing several installments, subscription cycles, or cart items
  # counts once. A dispute counts only while it stands: reversed (won) chargebacks are
  # excluded, matching how #lost_chargebacks measures the rate.
  #
  # settled_count (raw purchases) is still returned because the enforcement volume gate
  # (MIN_SETTLED_PURCHASES_FOR_REFUND_POLICY_ENFORCEMENT) measures sales volume, which is
  # inherently a purchase count.
  def dispute_rate_stats
    # purchases.email has no database-level NOT NULL constraint, so legacy or
    # validation-bypassing rows can carry a NULL email. COUNT(DISTINCT email) would
    # silently drop those rows from both the numerator and the denominator. An unknown
    # buyer can't be de-duplicated, so each null-email purchase falls back to counting
    # as its own buyer (keyed by the purchase id).
    buyer_key = Arel.sql("COALESCE(purchases.email, CONCAT('missing-email-', purchases.id))")

    settled_count = sales.successful.count
    settled_buyers_count = sales.successful.distinct.count(buyer_key)
    disputing_buyers_count = sales.successful
                                  .where.not(chargeback_date: nil)
                                  .where("purchases.flags & ? = 0", Purchase.flag_mapping["flags"][:chargeback_reversed])
                                  .distinct
                                  .count(buyer_key)
    rate = settled_buyers_count > 0 ? disputing_buyers_count * 100.0 / settled_buyers_count : nil
    { settled_count:, settled_buyers_count:, disputing_buyers_count:, rate: }
  end

  def enable_refunds!
    self.refunds_disabled = false
    save!
  end

  def disable_refunds!
    self.refunds_disabled = true
    save!
  end

  def flagged_for_explicit_nsfw?
    flagged_for_tos_violation? && tos_violation_reason == Compliance::EXPLICIT_NSFW_TOS_VIOLATION_REASON
  end

  def flag_for_explicit_nsfw_tos_violation!(options)
    transaction do
      update!(tos_violation_reason: Compliance::EXPLICIT_NSFW_TOS_VIOLATION_REASON)

      comment_content = "All products were unpublished because this user was selling prohibited content."
      flag_for_tos_violation!(options.merge(bulk: true, content: comment_content))

      ContactingCreatorMailer.flagged_for_explicit_nsfw_tos_violation(id).deliver_later(queue: "default")

      links.alive.find_each do |product|
        product.unpublish!(is_unpublished_by_admin: true)
      end
    end
  end

  def suspend_due_to_stripe_risk(disabled_reason: nil)
    transaction do
      update!(tos_violation_reason: "Stripe reported high risk")
      suspend_for_tos_violation!(author_name: "stripe_risk", bulk: true) unless suspended?
      links.alive.find_each do |product|
        product.unpublish!(is_unpublished_by_admin: true)
      end
      note = "Suspended because of high risk reported by Stripe"
      note += " (Stripe requirements.disabled_reason: #{disabled_reason})" if disabled_reason.present?
      comments.create!(
        author_name: "stripe_risk",
        comment_type: Comment::COMMENT_TYPE_SUSPENSION_NOTE,
        content: note
      )
      ContactingCreatorMailer.suspended_due_to_stripe_risk(id).deliver_later
    end
  end

  def not_verified?
    !verified
  end

  def disable_links_and_tell_chat
    links.each do |link|
      link.update(banned_at: Time.current)
    end
  end

  def enable_links_and_tell_chat
    links.each do |link|
      link.update(banned_at: nil)
    end
  end

  def suspend_sellers_other_accounts(transition)
    return if transition.args.first&.dig(:skip_transition_callback) == __method__

    SuspendAccountsWithPaymentAddressWorker.perform_in(5.seconds, id)
  end

  def block_seller_ip!
    BlockSuspendedAccountIpWorker.perform_in(5.seconds, id)
  end

  def remove_follows_for_suspended_account!
    RemoveSuspendedAccountFollowsWorker.perform_in(5.seconds, id)
  end

  def enable_sellers_other_accounts(transition)
    return if transition.args.first&.dig(:skip_transition_callback) == __method__

    enable_accounts_with_same_payment_address
    enable_accounts_with_same_stripe_fingerprint
  end

  # True when the most recent suspension on this account was written by the account cascade
  # (SuspendAccountsWithPaymentAddressWorker suspends siblings under that author name) rather
  # than by a review of this account on its own merits.
  #
  # Called from inside the compliant transition while the row is locked, never from the
  # cascade itself — see #release_cascade_suspended_sibling for why.
  def suspended_by_account_cascade?
    last_suspension = comments
      .where(comment_type: Comment::COMMENT_TYPE_SUSPENDED)
      .order(:created_at, :id)
      .last

    last_suspension&.author_name == "suspend_sellers_other_accounts"
  end

  # These two mirror suspend_sellers_other_accounts: when an account is cleared, the sibling
  # accounts that were auto-suspended alongside it are cleared too.
  def enable_accounts_with_same_payment_address
    return if payment_address.blank?

    User.where(payment_address:).where.not(id:).each do |user|
      release_cascade_suspended_sibling(user, "Marked compliant automatically on #{Time.current.to_fs(:formatted_date_full_month)} as payment address #{payment_address} is now unblocked (from User##{id})")
    end
  end

  def enable_accounts_with_same_stripe_fingerprint
    fingerprints = bank_accounts.where.not(stripe_fingerprint: [nil, ""]).distinct.pluck(:stripe_fingerprint)
    return if fingerprints.empty?

    user_ids_with_same_fingerprint = BankAccount.alive
      .where(stripe_fingerprint: fingerprints)
      .where.not(user_id: id)
      .distinct
      .pluck(:user_id)

    User.where(id: user_ids_with_same_fingerprint).each do |user|
      matching_fingerprint = (fingerprints & user.alive_bank_accounts.pluck(:stripe_fingerprint)).first
      release_cascade_suspended_sibling(user, "Marked compliant automatically on #{Time.current.to_fs(:formatted_date_full_month)} as bank account fingerprint #{matching_fingerprint} is now unblocked (from User##{id})")
    end
  end

  # Releases one sibling account.
  #
  # The cascade may only undo its own work. The suspend side skips accounts that are already
  # suspended (`User.not_suspended`), so an account suspended on its own merits never entered
  # the cascade and must not be released by it — that suspension was a separate decision that
  # nobody here has reviewed.
  #
  # Asking "did the cascade suspend this sibling?" here would be asking too early: another
  # enforcement lane can suspend the sibling in the moment between the answer and the write,
  # and the write would then clear a suspension the answer never saw. So we pass the question
  # instead of the answer — `clear_suspension: :if_suspended_by_account_cascade` — and the
  # transition resolves it while holding the row lock.
  #
  # A refusal means another lane owns this sibling's suspension; it stays suspended and the
  # remaining siblings are still processed. Nothing has been written at the point the
  # transition refuses, so there is no partial update to unwind.
  def release_cascade_suspended_sibling(user, content)
    user.mark_compliant!(
      author_name: "enable_sellers_other_accounts",
      content:,
      skip_transition_callback: :enable_sellers_other_accounts,
      clear_suspension: :if_suspended_by_account_cascade
    )
  rescue SuspensionClearNotAuthorizedError
    nil
  end

  def unblock_seller_ip!
    return if last_sign_in_ip.blank?
    PlatformBlock.ip_address.where(object_value: last_sign_in_ip).find_each(&:unblock!)
  end

  def delete_custom_domain!
    return if custom_domain.nil?
    return if custom_domain.deleted?

    custom_domain.mark_deleted!
  end

  def suspended?
    suspended_for_tos_violation? || suspended_for_fraud?
  end
  alias_method :suspended, :suspended?

  def flagged?
    flagged_for_tos_violation? || flagged_for_fraud?
  end

  def suspended_by_admin?
    return false unless suspended?

    last_suspension_comment = comments
      .where(comment_type: Comment::COMMENT_TYPE_SUSPENDED)
      .order(:created_at)
      .last

    last_suspension_comment&.author_id.present?
  end

  # A suspension is only ever cleared on purpose. Anything moving an account to compliant
  # has to pass `clear_suspension: true` when the account is actually suspended, to say that
  # it looked at the suspension and still means to lift it.
  #
  # Without this, any review that ends in "this account looks fine" silently un-suspends a
  # seller. That happened: a seller was suspended for selling pirated content, and 106
  # seconds later an unrelated first-payout review — which only looks at financial signals
  # like chargebacks and refunds, and had no idea a suspension had just been written —
  # marked the same account compliant. The products went back on sale and the account sold
  # for another eight days before anyone noticed.
  #
  # The state the caller thinks the account is in can be stale (that's the whole shape of
  # the bug: the losing lane loaded the account before the suspension was written), so the
  # check reads the row inside the transition's own transaction with a row lock rather than
  # trusting the attribute in memory. The lock also serializes two lanes racing on the same
  # account, so the second one sees the first one's suspension instead of overwriting it.
  def refuse_unauthorized_suspension_clear(transition)
    return true if new_record?

    persisted_risk_state = self.class.where(id:).lock.pick(:user_risk_state)
    return true unless SUSPENDED_STATES.include?(persisted_risk_state)

    params = transition.args.first || {}
    unless suspension_clear_authorized?(params[:clear_suspension])
      raise SuspensionClearNotAuthorizedError,
            "refusing to clear #{persisted_risk_state}: the caller did not authorize clearing this suspension"
    end

    true
  end

  # `clear_suspension` is either an unconditional yes (a human admin, or an internal-API
  # caller who passed clear_suspension=true) or the account cascade's conditional yes,
  # `:if_suspended_by_account_cascade`. The conditional form is resolved here rather than at
  # the call site because only here are we holding the row lock: the ownership question and
  # the write that depends on the answer have to be the same moment, or a suspension landing
  # in between gets cleared by an authorization that never saw it.
  def suspension_clear_authorized?(clear_suspension)
    return suspended_by_account_cascade? if clear_suspension == :if_suspended_by_account_cascade

    !!clear_suspension
  end

  def add_user_comment(transition)
    params = transition.args.first
    raise ArgumentError, "first transition argument must include an author_id or author_name" if !params || (!params[:author_id] && !params[:author_name])

    author_name = params[:author_name] || User.find(params[:author_id])&.name_or_username
    date = Time.current.to_fs(:formatted_date_full_month)
    content = case transition.to_name
              when :compliant
                "Marked compliant by #{author_name} on #{date}"
              when :not_reviewed
                "Marked \"Not Reviewed\" by #{author_name} on #{date}"
              when :on_probation
                "Probated (payouts suspended) by #{author_name} on #{date}"
              when :flagged_for_tos_violation
                params[:product_id].present? ?
                  "Flagged for a policy violation by #{author_name} on #{date} for product named '#{Link.find(params[:product_id]).name}'" :
                  "Flagged for a policy violation by #{author_name} on #{date}"
              when :suspended_for_tos_violation
                "Suspended for a policy violation by #{author_name} on #{date}"
              when :flagged_for_fraud
                "Flagged for fraud by #{author_name} on #{date}"
              when :suspended_for_fraud
                "Suspended for fraud by #{author_name} on #{date}"
              else
                transition.to_name.to_s.humanize
    end
    comment_type = case transition.to_name
                   when :compliant
                     Comment::COMMENT_TYPE_COMPLIANT
                   when :not_reviewed
                     Comment::COMMENT_TYPE_NOT_REVIEWED
                   when :on_probation
                     Comment::COMMENT_TYPE_ON_PROBATION
                   when :flagged_for_fraud, :flagged_for_tos_violation
                     Comment::COMMENT_TYPE_FLAGGED
                   when :suspended_for_fraud, :suspended_for_tos_violation
                     Comment::COMMENT_TYPE_SUSPENDED
                   else
                     transition.to_name.slice(/[^_]*/)
    end
    comments.create!(
      content: params[:content] || content,
      author_id: params[:author_id],
      author_name: params[:author_name],
      comment_type:
    )
  end

  def add_product_comment(transition)
    params = transition.args.first
    return if params && params[:bulk]
    raise ArgumentError, "first transition argument must include a product_id" if !params || !params[:product_id]

    action_taken = transition.to_name.to_s.humanize
    action_reason = tos_violation_reason
    product = Link.find_by(id: params[:product_id])
    product.comments.create!(
      content: params[:content] || "#{action_taken} as #{action_reason}",
      author_id: params[:author_id],
      author_name: params[:author_name],
      comment_type: transition.to_name.slice(/[^_]*/)
    )
  end

  PAYOUTS_STATUSES = %w[paused payable].freeze
  PAYOUTS_STATUSES.each do |status|
    self.const_set("PAYOUTS_STATUS_#{status.upcase}", status)
  end

  def payouts_status
    @_account_with_paused_payouts_state ||= \
      if payouts_paused?
        PAYOUTS_STATUS_PAUSED
      else
        PAYOUTS_STATUS_PAYABLE
      end
  end

  PAYOUT_PAUSE_SOURCES = %w[stripe admin system user].freeze
  PAYOUT_PAUSE_SOURCES.each do |source|
    self.const_set("PAYOUT_PAUSE_SOURCE_#{source.upcase}", source)
  end

  SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS = {
    repeated_failed_payouts: "pause_payouts_after_repeated_failures",
    high_chargeback_rate: "pause_payouts_for_seller_based_on_chargeback_rate",
    recent_failed_purchases: "pause_payouts_for_seller_based_on_recent_failures",
  }.freeze

  # Of the three system comment authors above, only these two actually pause payouts.
  # `recent_failed_purchases` writes the same kind of comment but deliberately leaves payouts
  # alone (see Purchase::Blockable — it only flags the account for review), so it must never be
  # read as "this is why payouts are paused".
  SYSTEM_PAYOUT_PAUSING_COMMENT_AUTHORS = SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS
    .values_at(:repeated_failed_payouts, :high_chargeback_rate).freeze

  # Comment left when the automatic re-check (ReleaseChargebackRatePayoutPausesJob) lifts a hold.
  CHARGEBACK_RATE_PAYOUT_RESUME_COMMENT_AUTHOR = "release_payouts_for_seller_based_on_chargeback_rate"

  # True when this account's payouts are currently held by the automatic chargeback-rate check
  # (Purchase::Blockable#pause_payouts_for_seller_based_on_chargeback_rate!) rather than by an
  # admin, by Stripe, by the seller themselves, or by the repeated-failed-payouts check.
  #
  # Both of the pausing checks write a probation comment and both set the pause source to
  # "system", so the source column alone can't tell them apart — the most recent comment from a
  # pausing author is what identifies the current hold.
  #
  # This deliberately does NOT filter to alive comments, and must not be "cleaned up" to. A
  # soft-deleted newer comment from the other pausing check still suppresses the answer here,
  # which is the safe direction: the worst case is that an account keeps a hold an admin can lift
  # by hand. Filtering to alive would let deleting a comment turn an older chargeback comment into
  # the apparent current hold and release payouts on an account paused for a different reason.
  # The candidate scan in ReleaseChargebackRatePayoutPausesJob does filter to alive, so a retracted
  # chargeback comment simply stops being auto-released — the same fail-closed direction.
  def payouts_paused_for_chargeback_rate?
    return false unless payouts_paused_internally?
    return false unless payouts_paused_by_source == PAYOUT_PAUSE_SOURCE_SYSTEM

    last_pausing_author = comments.with_type_on_probation
                                  .where(author_name: SYSTEM_PAYOUT_PAUSING_COMMENT_AUTHORS)
                                  .order(:created_at, :id)
                                  .last&.author_name

    last_pausing_author == SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:high_chargeback_rate]
  end

  # True when the chargeback-volume hold should pay 75% and keep 25% unpaid, rather than skip.
  # Other system pauses (repeated failed payouts) stay a full block.
  def chargeback_rate_payout_reserve_active?
    return false if Feature.active?(:disable_chargeback_rate_payout_reserve)

    payouts_paused_for_chargeback_rate?
  end

  # Admin-callable: lifts an automatic refund-policy enforcement (see
  # Purchase::Blockable#enforce_refund_policy_for_seller_based_on_dispute_rate!).
  # The seller keeps whatever refund period they currently have, but can pick
  # "No refunds allowed" again. Leaves an audit comment so admins can see when
  # and why enforcement was cleared.
  def clear_refund_policy_enforcement!
    return unless refund_policy_enforced?

    update!(refund_policy_enforced: false)
    comments.create!(
      content: "Refund policy enforcement cleared — seller can customize their refund policy again.",
      comment_type: Comment::COMMENT_TYPE_NOTE,
      author_name: REFUND_POLICY_ENFORCEMENT_COMMENT_AUTHOR
    )
  end

  class_methods do
  end
end
