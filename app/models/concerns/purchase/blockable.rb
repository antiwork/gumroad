# frozen_string_literal: true

module Purchase::Blockable
  extend ActiveSupport::Concern

  included do
    include AttributeBlockable

    attr_blockable :browser_guid
    attr_blockable :ip_address
    attr_blockable :email
    attr_blockable :paypal_email, object_type: :email
    attr_blockable :gifter_email, object_type: :email
    attr_blockable :charge_processor_fingerprint
    attr_blockable :purchaser_email, object_type: :email
    attr_blockable :recent_stripe_fingerprint, object_type: :charge_processor_fingerprint
    attr_blockable :email_domain
    attr_blockable :paypal_email_domain, object_type: :email_domain
    attr_blockable :gifter_email_domain, object_type: :email_domain
    attr_blockable :purchaser_email_domain, object_type: :email_domain

    delegate :email, to: :purchaser, prefix: true, allow_nil: true
  end

  # Max number of failed purchase card fingerprints before a buyer's browser guid gets banned
  MAX_NUMBER_OF_FAILED_FINGERPRINTS = 4

  # Not private, unlike the other card-testing settings below: Onetime::ClearMistakenBuyerBlocks
  # has to reproduce these two velocity checks exactly, so that a one-off cleanup never clears a
  # block row that a velocity rule also wanted. Reading the same constant is what keeps the two
  # from drifting apart.
  CARD_TESTING_WATCH_PERIOD = 7.days

  CARD_TESTING_IP_ADDRESS_WATCH_PERIOD = 1.day

  CARD_TESTING_IP_ADDRESS_BLOCK_DURATION = 7.days
  private_constant :CARD_TESTING_IP_ADDRESS_BLOCK_DURATION

  IGNORED_ERROR_CODES = [PurchaseErrorCode::PERCEIVED_PRICE_CENTS_NOT_MATCHING,
                         PurchaseErrorCode::NOT_FOR_SALE,
                         PurchaseErrorCode::TEMPORARILY_BLOCKED_PRODUCT,
                         PurchaseErrorCode::BLOCKED_CHARGE_PROCESSOR_FINGERPRINT,
                         PurchaseErrorCode::BLOCKED_CUSTOMER_EMAIL_ADDRESS,
                         PurchaseErrorCode::BLOCKED_CUSTOMER_CHARGE_PROCESSOR_FINGERPRINT,
                         PurchaseErrorCode::EXCEEDING_OFFER_CODE_QUANTITY]
  private_constant :IGNORED_ERROR_CODES

  MAX_BUYER_CHARGEBACKS_BEFORE_BLOCK = 5

  # How many of the buyer's other purchases #unblock_buyer! collects identifiers from. An admin
  # click has to stay bounded, and past a few hundred rows a buyer stops contributing new browser
  # guids, addresses or cards — the largest stranded buyer in gumroad-private#1648 had 231
  # purchases and 85 distinct guids.
  MAX_SIBLING_PURCHASES_FOR_UNBLOCK = 500

  # How many settled purchases a buyer needs behind them before a fraud-flavoured decline from
  # their card issuer stops being treated as a fraud signal about the person. Three is well above
  # what a card tester accumulates and well below what an ordinary repeat customer or a membership
  # subscriber has.
  MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY = 3

  # Purchases only start counting towards clean history once they are this old. A card tester whose
  # stolen card went through today has a "successful" purchase; what they do not have is a purchase
  # old enough for the cardholder to have noticed and disputed it. Comfortably longer than the usual
  # dispute-notification lag, and no obstacle to a real customer, who by definition bought before.
  MIN_PURCHASE_AGE_FOR_CLEAN_HISTORY = 60.days

  MAX_PURCHASER_AGE_FOR_SUSPENSION = 6.hours
  private_constant :MAX_PURCHASER_AGE_FOR_SUSPENSION

  def buyer_blocked?
    blocked_by_browser_guid? ||
      blocked_by_email? ||
      blocked_by_paypal_email? ||
      blocked_by_gifter_email? ||
      blocked_by_purchaser_email? ||
      blocked_by_ip_address? ||
      blocked_by_charge_processor_fingerprint? ||
      blocked_by_recent_stripe_fingerprint?
  end

  def block_buyer!(blocking_user_id: nil, comment_content: nil)
    block_by_browser_guid!(by_user_id: blocking_user_id)
    block_by_email!(by_user_id: blocking_user_id)
    block_by_paypal_email!(by_user_id: blocking_user_id)
    block_by_gifter_email!(by_user_id: blocking_user_id)
    block_by_purchaser_email!(by_user_id: blocking_user_id)
    block_by_ip_address!(by_user_id: blocking_user_id, expires_in: PlatformBlock::IP_ADDRESS_BLOCKING_DURATION_IN_MONTHS.months)
    block_by_charge_processor_fingerprint!(by_user_id: blocking_user_id)
    block_by_recent_stripe_fingerprint!(by_user_id: blocking_user_id)

    blocking_user = User.find_by(id: blocking_user_id) if blocking_user_id.present?
    update!(is_buyer_blocked_by_admin: true) if blocking_user&.is_team_member?

    create_blocked_buyer_comments!(blocking_user:, comment_content:)
  end

  # Unblocking is scoped to the BUYER, not to this one purchase row. The purchase an agent opens
  # to press Unblock is almost never the purchase the block was written from — a buyer browses
  # from several devices over the years, so unblocking from purchase A cleared guid A while the
  # block sat on guid B and kept rejecting them. #block_buyer! is symmetric with the old
  # single-row unblock, so the round trip looked fine on the acting row and nothing anywhere said
  # a row had been left behind: `buyer_blocked?` is an OR, the controller still wrote "Buyer
  # unblocked", and the response was still `success: true`. Browser-guid blocks are the worst ones
  # to strand, because PlatformBlock.add! only accepts an `expires_in` for ip_address and so a guid
  # block never lapses (gumroad-private#1648: 71% of hand-unblocked buyers were still blocked, one
  # of them for 2.5 years).
  #
  # IP addresses are deliberately NOT widened across rows. An IP is not buyer-bound — it is shared
  # by everyone behind a NAT or a carrier pool and gets reallocated — so clearing every IP this
  # buyer has ever checked out from would lift blocks earned by other people. It also expires on
  # its own. The identifiers widened here are the ones that identify this buyer specifically:
  # their browser, their email addresses and their cards.
  #
  # Returns the PlatformBlocks that are STILL active afterwards, so a caller can tell the agent the
  # truth instead of reporting an unqualified success. Non-empty means something outside this
  # buyer's identifiers is holding them (an email-domain block, a shared IP).
  def unblock_buyer!
    unblock_by_ip_address!

    buyer_blockable_values.each do |object_type, values|
      PlatformBlock.where(object_type:, object_value: values).find_each(&:unblock!)
    end
    @blocked_by_attributes = nil

    update!(is_buyer_blocked_by_admin: false) if is_buyer_blocked_by_admin?

    surviving_buyer_blocks
  end

  # Every active block that still holds this buyer after an unblock. Same identifier set
  # `buyer_blocked?` asks about, but resolved across the buyer's purchases and returning the rows
  # rather than a boolean, so the caller can name what survived.
  #
  # Also reports blocks on same-email guest rows that failed the corroboration bar in
  # #corroborated_guest_purchases. Those are blocks the unblock refused to clear because the row
  # may be somebody else's; reporting them keeps the refusal visible, so the agent sees the
  # surviving row and judges it instead of the response reading as a full success while the buyer
  # may still be held — the silence gumroad-private#1648 is about.
  def surviving_buyer_blocks
    scopes = buyer_blockable_values.map { |object_type, values| PlatformBlock.active.where(object_type:, object_value: values) }
    scopes << PlatformBlock.active.ip_address.where(object_value: ip_address) if ip_address.present?
    blockable_values_for(same_email_guest_purchases - sibling_buyer_purchases).each do |object_type, values|
      scopes << PlatformBlock.active.where(object_type:, object_value: values)
    end
    return PlatformBlock.none if scopes.empty?

    scopes.reduce { |combined, scope| combined.or(scope) }
  end

  private def buyer_blockable_values
    @_buyer_blockable_values ||= blockable_values_for([self, *sibling_buyer_purchases], extra_fingerprints: [recent_stripe_fingerprint])
  end

  private def blockable_values_for(purchases, extra_fingerprints: [])
    guids = Set.new
    emails = Set.new
    fingerprints = Set.new

    purchases.each do |purchase|
      guids << purchase.browser_guid
      emails.merge([purchase.email, purchase.paypal_email, purchase.gifter_email, purchase.purchaser_email])
      fingerprints << purchase.charge_processor_fingerprint
    end
    fingerprints.merge(extra_fingerprints)

    {
      PlatformBlock::TYPES[:browser_guid] => guids.compact_blank.to_a,
      PlatformBlock::TYPES[:email] => emails.compact_blank.to_a,
      PlatformBlock::TYPES[:charge_processor_fingerprint] => fingerprints.compact_blank.to_a,
    }.reject { |_, values| values.empty? }
  end

  # The buyer's other purchases, this one excluded: rows that resolved to the same account, plus
  # guest rows a second identifier ties to the buyer (see #corroborated_guest_purchases). Newest
  # first and capped per branch — a buyer with thousands of rows contributes no new identifiers
  # past the first few hundred, and an admin click must not turn into an unbounded scan.
  # Deliberately not memoized: #block_buyer! reads #recent_stripe_fingerprint through the
  # attr-blockable machinery, so a memo taken then would still be live at unblock time and hide
  # any purchase the buyer made in between.
  private def sibling_buyer_purchases
    account_purchases =
      if purchaser_id.present?
        Purchase.where(purchaser_id:).where.not(id:).order(id: :desc).limit(MAX_SIBLING_PURCHASES_FOR_UNBLOCK).to_a
      else
        []
      end

    account_purchases + corroborated_guest_purchases(account_purchases)
  end

  # The buyer's guest checkouts: same-email rows that resolved to no account at all. A checkout
  # email is unauthenticated — anyone can type anyone's address, and card testers do exactly that —
  # so sharing the email is NOT enough to call a guest row this buyer's: a tester who checked out
  # under this buyer's address would otherwise get their own browser and card unblocked whenever
  # an admin unblocks the buyer. A guest row only counts when its card fingerprint matches a row
  # we already trust (this one, or an account-bound sibling) — the fingerprint is derived from a
  # physical card in the buyer's hands, so it is the one corroborating identifier that is itself
  # buyer-bound. A browser guid match deliberately does NOT corroborate: a guid names a browser,
  # and browsers are shared, so another person's guest checkout under the buyer's email on the
  # buyer's machine would match on guid and get their own card unblocked. One hop only — a
  # corroborated guest row does not corroborate further rows. Rows that fail the bar contribute
  # nothing here; their blocks are surfaced by #surviving_buyer_blocks for a human to judge.
  #
  # Same-email rows that resolved to a DIFFERENT account are excluded outright, corroborated or
  # not — those identifiers belong to that account's blocks, not this buyer's.
  private def corroborated_guest_purchases(account_purchases)
    trusted_fingerprints = [self, *account_purchases].map(&:charge_processor_fingerprint).compact_blank.to_set

    same_email_guest_purchases.select do |candidate|
      trusted_fingerprints.include?(candidate.charge_processor_fingerprint)
    end
  end

  private def same_email_guest_purchases
    return [] if email.blank?

    Purchase.where(email:, purchaser_id: nil).where.not(id:).order(id: :desc).limit(MAX_SIBLING_PURCHASES_FOR_UNBLOCK).to_a
  end

  def charge_processor_fingerprint
    stripe_charge_processor? ? stripe_fingerprint : card_visual
  end

  def block_buyer_based_on_chargeback_count!
    email_cb_count = Purchase.where(email: email)
                             .where.not(chargeback_date: nil)
                             .count

    purchaser_cb_count = if purchaser_id.present?
      Purchase.where(purchaser_id: purchaser_id)
              .where.not(chargeback_date: nil)
              .count
    else
      0
    end

    chargeback_count = [email_cb_count, purchaser_cb_count].max

    return if chargeback_count < MAX_BUYER_CHARGEBACKS_BEFORE_BLOCK
    return if buyer_blocked?

    block_buyer!(
      blocking_user_id: GUMROAD_ADMIN_ID,
      comment_content: "Auto-blocked: buyer has #{chargeback_count} chargebacks (#{email_cb_count} by email, #{purchaser_cb_count} by account)"
    )
  end

  def pause_payouts_for_seller_based_on_chargeback_rate!
    return unless seller.present?
    return if [User::PAYOUT_PAUSE_SOURCE_ADMIN, User::PAYOUT_PAUSE_SOURCE_SYSTEM].include?(seller.payouts_paused_by_source)

    chargeback_stats = seller.lost_chargebacks
    chargeback_volume_percentage = chargeback_stats[:volume]
    return if chargeback_volume_percentage == "NA"

    volume_rate = chargeback_volume_percentage.to_f
    return if volume_rate <= User::MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS

    # Flag and comment must land together — see the same note in Payment. Both automatic checks
    # write source "system", so the comment is the only thing that says which one holds this
    # account, and a gap between the two writes is a window where the hold is misattributed.
    User.transaction do
      seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
      seller.comments.create(
        content: "Payouts automatically paused due to chargeback rate (#{chargeback_volume_percentage}) exceeding #{User::MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS}% volume.",
        comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
        author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:high_chargeback_rate]
      )
    end
  end

  # Called when a dispute (chargeback) lands on one of this seller's purchases.
  # If the seller's lifetime dispute rate — unique buyers with a standing chargeback
  # divided by unique buyers with settled successful purchases — crosses 1%, we force a
  # buyer-friendly refund policy on their
  # account: their seller-level refund policy is bumped to at least a 30-day money-back
  # guarantee and they can no longer pick "No refunds allowed" (the guard lives in
  # RefundPolicy's validation) until an admin clears the enforcement with
  # User#clear_refund_policy_enforcement!.
  #
  # Why: a large share of disputes are "credit_not_processed" — buyers who asked for a
  # refund, were stonewalled by a no-refunds policy, and went to their bank instead.
  # Forcing a refund path is cheaper for everyone than eating the chargeback + fee.
  def enforce_refund_policy_for_seller_based_on_dispute_rate!
    return unless seller.present?
    # Idempotent: once enforcement is on, a later dispute shouldn't re-bump the policy
    # or spam duplicate admin comments.
    return if seller.refund_policy_enforced?

    stats = seller.dispute_rate_stats
    # Volume gates: don't act on statistical noise from small accounts. Settled purchases
    # gate sales volume; the dispute gate counts distinct disputing buyers, so one buyer
    # disputing several installments of the same purchase can't clear it alone.
    return if stats[:settled_count] < User::MIN_SETTLED_PURCHASES_FOR_REFUND_POLICY_ENFORCEMENT
    return if stats[:disputing_buyers_count] < User::MIN_DISPUTING_BUYERS_FOR_REFUND_POLICY_ENFORCEMENT

    dispute_count_rate = stats[:rate]
    return if dispute_count_rate.nil? || dispute_count_rate <= User::MAX_DISPUTE_COUNT_RATE_ALLOWED_FOR_CUSTOM_REFUND_POLICY

    # All three writes happen together or not at all. If the flag were saved first and the
    # policy bump or audit comment then failed, the seller would be stuck marked as enforced
    # (the guard above skips retries) without the promised policy change or paper trail.
    seller.transaction do
      seller.update!(refund_policy_enforced: true)

      # A "No refunds allowed" (0-day) policy is the one that drives buyers to their bank,
      # so bump it to the enforced minimum. Longer periods the seller already offers are fine.
      refund_policy = seller.refund_policy
      if refund_policy.present? && refund_policy.max_refund_period_in_days.zero?
        refund_policy.update!(max_refund_period_in_days: User::ENFORCED_MIN_REFUND_PERIOD_IN_DAYS)
      end

      seller.comments.create!(
        content: "Refund policy enforcement applied: dispute rate #{format("%.1f%%", dispute_count_rate)} " \
                 "(#{stats[:disputing_buyers_count]} disputing buyers / #{stats[:settled_buyers_count]} unique buyers) exceeded " \
                 "#{User::MAX_DISPUTE_COUNT_RATE_ALLOWED_FOR_CUSTOM_REFUND_POLICY}% by count. Seller-level refund policy " \
                 "is now at least a #{User::ENFORCED_MIN_REFUND_PERIOD_IN_DAYS}-day money-back guarantee and " \
                 "\"No refunds allowed\" is unavailable until an admin clears the enforcement.",
        comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
        author_name: User::REFUND_POLICY_ENFORCEMENT_COMMENT_AUTHOR
      )
    end

    # Let the creator know their refund policy changed and why — a silent policy
    # change would be confusing and unfair. Enqueued after the transaction block
    # so the email can't go out if the enforcement writes roll back.
    ContactingCreatorMailer.refund_policy_enforced_notification(seller.id).deliver_later
  end

  # True when the person behind this purchase has a payment record that speaks for itself: several
  # settled purchases they actually paid for, none refunded, none under a standing dispute, and old
  # enough that a defrauded cardholder would have complained by now.
  #
  # Free purchases are excluded on purpose. They always succeed, so counting them would let anybody
  # mint the history that exempts them from the block below by downloading three free products.
  #
  # Whose history counts is the delicate part, and it is deliberately NOT "whoever this purchase
  # says it belongs to".
  #
  # The only identity we accept here is the card itself. A Stripe fingerprint is derived from the
  # card number, so a run of settled, undisputed purchases on this fingerprint is proof that THIS
  # CARD has paid us before and nobody complained. Nothing the person filling in a checkout form
  # can type gets them somebody else's fingerprint.
  #
  # Email addresses and accounts are not accepted, on a renewal either. An unauthenticated
  # checkout supplies its own email address and purchase creation resolves an account from it
  # (Purchase::CreateService#set_purchaser_for) without ever proving the person owns it — and that
  # unproven identity is what a subscription then persists as its own (`subscription.user`) and
  # copies onto every later charge (Subscription#build_purchase). So "this came from our records,
  # not from this request" is true of a renewal and still says nothing about who the buyer is:
  # somebody can start a membership under an established customer's address today and have a
  # later renewal on a stolen card inherit that customer's clean record. Until we persist identity
  # that was actually authenticated, the card is the only provenance we have.
  #
  # The subscriber this exemption exists for — a long-standing member whose bank reissued their
  # card (gumroad-private#1480) — is still covered: the card on file that just declined is the
  # same card their previous renewals settled on, so its own history clears them.
  def buyer_has_clean_payment_history?
    return false if stripe_fingerprint.blank?

    Purchase.successful.non_free.not_fully_refunded.not_chargedback_or_chargedback_reversed
            .where(created_at: ..MIN_PURCHASE_AGE_FOR_CLEAN_HISTORY.ago)
            .where.not(id:)
            .where(stripe_fingerprint:)
            .limit(MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY)
            .count >= MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY
  end

  private
    def recent_stripe_fingerprint
      [self, *sibling_buyer_purchases].select { |purchase| purchase.stripe_fingerprint.present? }.max_by(&:id)&.stripe_fingerprint
    end

    def blockable_emails_if_fraudulent_transaction
      [purchaser_email, paypal_email, email, gifter_email].compact_blank.uniq
    end

    [:purchaser_email, :paypal_email, :gifter_email, :email].each do |email_attribute|
      define_method("#{email_attribute}_domain") do
        send(email_attribute).presence && Mail::Address.new(send(email_attribute)).domain
      end
    end

    def blocked_by_email_domain_if_fraudulent_transaction?
      blocked_by_email_domain? || blocked_by_paypal_email_domain? || blocked_by_gifter_email_domain? || blocked_by_purchaser_email_domain?
    end

    def ban_fraudulent_buyer_browser_guid!
      return unless stripe_fingerprint

      unique_failed_fingerprints = Purchase.failed.select("distinct stripe_fingerprint").where(
        "browser_guid = ? and stripe_fingerprint is not null", browser_guid
      )
      return if unique_failed_fingerprints.count < MAX_NUMBER_OF_FAILED_FINGERPRINTS

      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)
    end

    # A single fraud-flavoured decline from the card issuer used to platform-block everything we
    # know about the person who attempted the payment: their browser, their email addresses, their
    # IP address and their card. That is the right response to somebody testing a stolen card on us.
    # It is the wrong response to a long-standing customer whose bank reissued their card, which is
    # what the "lost card" and "pickup card" codes almost always mean in practice — and because we
    # blocked the email and the browser too, those customers could not pay us with a replacement
    # card either, so a renewal that should have recovered by itself turned into a lost membership
    # (gumroad-private#1480).
    #
    # Two guards now stand in front of the block:
    #
    #   1. Only the codes where the issuer is actually reporting card misuse count
    #      (PurchaseErrorCode::AUTO_BLOCK_ERROR_CODES). Lost/pickup declines still fail the charge,
    #      they just do not brand the buyer.
    #   2. A buyer with real successful payment history behind them is not blocked at all. Somebody
    #      who has paid us repeatedly, with nothing refunded and nothing charged back, is not a card
    #      tester; whatever the issuer is reporting, the right outcome is that they can put a new
    #      card in and carry on. Only history that the card itself proves counts — see
    #      #buyer_has_clean_payment_history?.
    #
    # And when we do block, we block the payment method only — see #block_buyer_payment_method!.
    def ban_buyer_on_fraud_related_error_code!
      failure_code = stripe_error_code || error_code
      return if PurchaseErrorCode::AUTO_BLOCK_ERROR_CODES.exclude?(failure_code)
      return if buyer_has_clean_payment_history?

      block_buyer_payment_method!
    end

    # Blocks the card this decline came in on, and — on a renewal, where the card is ours to look
    # up rather than the buyer's to claim — the card on file for the subscriber.
    #
    # Deliberately narrower than #block_buyer!: blocking the buyer's email, browser and IP takes
    # away the only route they have to fix the problem themselves (add a different card, pay
    # through PayPal), and there is no version of "your card was reported stolen" where we want to
    # stop the actual human from paying with a card that is fine. Somebody spraying many stolen
    # cards at us is still caught by the card-testing velocity checks (#ban_card_testers!,
    # #ban_fraudulent_buyer_browser_guid!), which do block the browser and the email once several
    # distinct cards have failed.
    #
    # A renewal does not always carry a fingerprint of its own — a charge can fail before we ever
    # record one — so for a recurring charge we also block the card that renewal was charged on,
    # when we can prove which card that was. See #subscription_card_fingerprint for what counts as
    # proof; when there is none, we block nothing beyond the failed charge's own fingerprint.
    #
    # The card is deliberately NOT looked up from the email or the account on the purchase. Both of
    # those can belong to somebody else: a membership can be started under an established customer's
    # address at an unauthenticated checkout (see #buyer_has_clean_payment_history?), so "the newest
    # card on any purchase sharing this email or account" — what #recent_stripe_fingerprint returns
    # — can be a bystander's working card, and a fingerprint-less renewal would get that card
    # blocked platform-wide. Subscription#credit_card_to_charge is avoided for the same reason: it
    # falls back to the account owner's card when the subscription has none of its own, and the
    # account is exactly the identity we cannot trust here.
    def block_buyer_payment_method!
      block_by_charge_processor_fingerprint!
      block_by_subscription_card_fingerprint! if is_recurring_subscription_charge
    end

    # The fingerprint of the card this failed renewal was charged on — but only when the
    # subscription's own purchase records prove that card was already paying for it before this
    # attempt. Nil otherwise, including when there is no subscription.
    #
    # Two things are going on here, and both matter.
    #
    # The card is read from this purchase's own `credit_card_id`, not from the subscription row.
    # `credit_card_id` is a snapshot taken when the renewal was built and charged, and nothing
    # rewrites it afterwards. `subscription.credit_card_id` moves: the buyer can replace their card,
    # and a charge held for Strong Customer Authentication fails up to a quarter of an hour after it
    # was attempted, so by the time this failure callback runs the subscription row can already point
    # at a different card. Reading it then would block a card this charge never touched while leaving
    # the one that actually declined alone.
    #
    # The snapshot on its own is not trustworthy either, because of where it can come from. When the
    # subscription holds no card of its own, both Subscription#build_purchase and
    # Purchase#load_chargeable_for_charging fall back to the card on the purchaser's account — and
    # that account is the identity we cannot trust, for the reason set out in
    # #buyer_has_clean_payment_history?: somebody can open a membership under an established
    # customer's email address at an unauthenticated checkout, and the account resolved from that
    # address carries the real customer's saved card. So we additionally require that an earlier
    # purchase of this same subscription was charged successfully on the same card. That is the
    # subscription itself having paid us with that card, recorded in purchase rows nobody edits
    # later. A card appearing for the first time on the failed attempt gets no fallback block: on a
    # genuine card-testing attempt the charge normally records its own fingerprint anyway, and being
    # wrong in the other direction blocks a bystander's working card platform-wide.
    #
    # That earlier purchase also has to be one money actually moved for. A renewal whose price came
    # out at zero — fully covered by a discount or by credit — is still recorded as `successful` and
    # still carries whichever card was on file at the time, even though nothing was charged to it.
    # Counting such a row would hand provenance to a card that never paid us: open a membership under
    # an established customer's email address at an unauthenticated checkout, let one zero-priced
    # renewal record their saved card, and a later fingerprint-less decline would block that
    # bystander's working card platform-wide. `non_free` keeps the proof to charges that settled.
    def subscription_card_fingerprint
      return if credit_card_id.blank?
      return if subscription.blank?
      return unless subscription.purchases.successful.non_free.where.not(id:).exists?(credit_card_id:)

      credit_card&.stripe_fingerprint
    end

    def block_by_subscription_card_fingerprint!
      fingerprint = subscription_card_fingerprint
      return if fingerprint.blank?

      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: fingerprint)
    end

    def suspend_buyer_on_fraudulent_card_decline!
      return if Feature.inactive?(:suspend_fraudulent_buyers)

      failure_code = stripe_error_code || error_code
      return unless failure_code == PurchaseErrorCode::CARD_DECLINED_FRAUDULENT
      return unless purchaser.present?
      return if purchaser.created_at < MAX_PURCHASER_AGE_FOR_SUSPENSION.ago
      return if purchaser.suspended?

      purchaser.flag_for_fraud!(author_name: "fraudulent_purchases_blocker") if purchaser.can_flag_for_fraud?
      purchaser.suspend_for_fraud!(author_name: "fraudulent_purchases_blocker") if purchaser.can_suspend_for_fraud?
    end

    def ban_card_testers!
      return unless stripe_fingerprint
      return if Feature.inactive?(:ban_card_testers)

      block_buyer_based_on_recent_failures!
      block_ip_address_based_on_recent_failures!
    end

    def block_buyer_based_on_recent_failures!
      unique_failed_fingerprints = Purchase.failed.stripe.with_stripe_fingerprint
                                           .select("distinct stripe_fingerprint")
                                           .where("email = ? or browser_guid = ?", email, browser_guid)
                                           .where(created_at: CARD_TESTING_WATCH_PERIOD.ago..)

      return if unique_failed_fingerprints.count < MAX_NUMBER_OF_FAILED_FINGERPRINTS

      block_buyer!
    end

    def flag_seller_based_on_recent_failures!
      return if Feature.inactive?(:block_seller_based_on_recent_failures)
      return if IGNORED_ERROR_CODES.include?(error_code)
      return if seller.verified?

      failed_seller_purchases_watch_minutes,
      max_seller_failed_purchases_price_cents,
      seller_age_threshold_days = $redis.mget(
        RedisKey.failed_seller_purchases_watch_minutes,
        RedisKey.max_seller_failed_purchases_price_cents,
        RedisKey.seller_age_threshold_days
      )

      seller_age_threshold_days = seller_age_threshold_days.try(:to_i) || 730 # 2 years
      return if seller.created_at < seller_age_threshold_days.days.ago

      failed_seller_purchases_watch_minutes = failed_seller_purchases_watch_minutes.try(:to_i) || 60 # 1 hour
      max_seller_failed_purchases_price_cents = max_seller_failed_purchases_price_cents.try(:to_i) || 200_000 # $2000

      failed_seller_purchases = seller.sales.failed.with_stripe_fingerprint
                                       .where(created_at: failed_seller_purchases_watch_minutes.minutes.ago..)

      failed_price_cents = failed_seller_purchases.sum(:price_cents)
      if failed_price_cents > max_seller_failed_purchases_price_cents
        # NOTE (2026-07-01, Sahil): do NOT pause the seller's payouts here. A failed-purchase
        # burst is almost always an EXTERNAL card-tester spraying stolen cards at a popular
        # checkout — the seller is the VICTIM, and freezing their money is a terrible UX that
        # punishes the wrong party. Keep the detection, but make it purely INFORMATIONAL:
        # post to the #risk room (relayed to Telegram) for a human/agent to review, and leave
        # payouts untouched. A genuine self-funding seller is caught by the risk-queue review
        # flow (per-card buyer spread + seller-IP intersection), not by this blunt volume trip.
        #
        # Dedup guard: this runs on EVERY failed purchase, so once the cumulative volume crosses
        # the threshold every subsequent failure in the same window would re-fire. Skip if we've
        # already flagged this seller within the watch window — one comment + one #risk post per
        # burst, not one per failed charge.
        return if seller.comments.where(
          comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
          author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:recent_failed_purchases],
          created_at: failed_seller_purchases_watch_minutes.minutes.ago..
        ).exists?

        failed_price_amount = MoneyFormatter.format(failed_price_cents, :usd, no_cents_if_whole: true, symbol: true)

        seller.comments.create(
          content: "High volume of failed purchases (#{failed_price_amount} USD in #{failed_seller_purchases_watch_minutes} minutes) — flagged for review (payouts NOT paused).",
          comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
          author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:recent_failed_purchases]
        )

        InternalNotificationWorker.perform_async(
          "risk",
          "Card-testing watch",
          "Seller #{seller.username || seller.external_id} (#{seller.email}) had #{failed_price_amount} in failed purchases in #{failed_seller_purchases_watch_minutes} minutes. Payouts were NOT paused — review for genuine self-funding vs. an external card-testing spray. Admin: #{seller.external_id}"
        )
      end
    end

    def block_ip_address_based_on_recent_failures!
      return if PlatformBlock.ip_address.active.find_by(object_value: ip_address).present?

      unique_failed_fingerprints = Purchase.failed.stripe.with_stripe_fingerprint
                                           .select("distinct stripe_fingerprint")
                                           .where("ip_address = ?", ip_address)
                                           .where(created_at: CARD_TESTING_IP_ADDRESS_WATCH_PERIOD.ago..)

      return if unique_failed_fingerprints.count < MAX_NUMBER_OF_FAILED_FINGERPRINTS

      PlatformBlock.add!(
        object_type: PlatformBlock::TYPES[:ip_address],
        object_value: ip_address,
        expires_in: CARD_TESTING_IP_ADDRESS_BLOCK_DURATION,
      )
    end

    def block_purchases_on_product!
      return if Feature.inactive?(:block_purchases_on_product)
      return if IGNORED_ERROR_CODES.include?(error_code)

      card_testing_product_watch_minutes,
      max_number_of_failed_purchases,
      card_testing_product_block_hours,
      max_number_of_failed_purchases_in_a_row,
      failed_purchases_in_a_row_watch_days = $redis.mget(
        RedisKey.card_testing_product_watch_minutes,
        RedisKey.card_testing_product_max_failed_purchases_count,
        RedisKey.card_testing_product_block_hours,
        RedisKey.card_testing_max_number_of_failed_purchases_in_a_row,
        RedisKey.card_testing_failed_purchases_in_a_row_watch_days
      )

      card_testing_product_watch_minutes = card_testing_product_watch_minutes.try(:to_i) || 10
      max_number_of_failed_purchases = max_number_of_failed_purchases.try(:to_i) || 60
      card_testing_product_block_hours = card_testing_product_block_hours.try(:to_i) || 6
      max_number_of_failed_purchases_in_a_row = max_number_of_failed_purchases_in_a_row.try(:to_i) || 10
      failed_purchases_in_a_row_watch_days = failed_purchases_in_a_row_watch_days.try(:to_i) || 2

      failed_purchase_attempts_count = link.sales
                                           .failed
                                           .not_recurring_charge
                                           .where("price_cents > 0")
                                           .where("error_code NOT IN (?) OR error_code IS NULL", IGNORED_ERROR_CODES)
                                           .where(created_at: card_testing_product_watch_minutes.minutes.ago..).count

      recent_purchases_failed_in_a_row = failed_purchases_count_redis_namespace.incr(failed_purchases_count_redis_key)
      failed_purchases_count_redis_namespace.expire(failed_purchases_count_redis_key, failed_purchases_in_a_row_watch_days.days.to_i)

      return if failed_purchase_attempts_count < max_number_of_failed_purchases \
             && recent_purchases_failed_in_a_row < max_number_of_failed_purchases_in_a_row

      PlatformBlock.add!(
        object_type: PlatformBlock::TYPES[:product],
        object_value: link_id,
        expires_in: card_testing_product_block_hours.hours,
      )
    end

    def block_fraudulent_free_purchases!
      return if total_transaction_cents.nonzero?

      free_purchases_watch_hours,
      max_allowed_free_purchases_of_same_product,
      fraudulent_free_purchases_block_hours = $redis.mget(
        RedisKey.free_purchases_watch_hours,
        RedisKey.max_allowed_free_purchases_of_same_product,
        RedisKey.fraudulent_free_purchases_block_hours
      )

      free_purchases_watch_hours = free_purchases_watch_hours&.to_i || 4
      max_allowed_free_purchases_of_same_product = max_allowed_free_purchases_of_same_product&.to_i || 2
      fraudulent_free_purchases_block_hours = fraudulent_free_purchases_block_hours&.to_i || 24 # 1 day

      recent_free_purchases_of_same_product = link.sales
                                                  .successful
                                                  .not_recurring_charge
                                                  .where(total_transaction_cents: 0)
                                                  .where(ip_address:)
                                                  .where(created_at: free_purchases_watch_hours.hours.ago..).count

      return if recent_free_purchases_of_same_product <= max_allowed_free_purchases_of_same_product

      PlatformBlock.add!(
        object_type: PlatformBlock::TYPES[:ip_address],
        object_value: ip_address,
        expires_in: fraudulent_free_purchases_block_hours.hours,
      )
    end

    def delete_failed_purchases_count
      failed_purchases_count_redis_namespace.del(failed_purchases_count_redis_key)
    end

    def failed_purchases_count_redis_key
      "product_#{link_id}"
    end

    def failed_purchases_count_redis_namespace
      @_failed_purchases_count_redis_namespace ||= Redis::Namespace.new(:failed_purchases_count, redis: $redis)
    end

    def create_blocked_buyer_comments!(blocking_user: nil, comment_content:)
      comment_params = { content: comment_content, comment_type: "note", author_id: blocking_user&.id || GUMROAD_ADMIN_ID }

      if comment_params[:content].blank?
        if blocking_user&.is_team_member?
          comment_params[:content] = "Buyer blocked by Admin (#{blocking_user.email})"
        elsif blocking_user.present?
          comment_params[:content] = "Buyer blocked by #{blocking_user.email}"
        else
          comment_params[:content] = "Buyer blocked"
        end
      end

      purchaser.comments.create!(comment_params.merge(purchase: self)) if purchaser.present?
      comments.create!(comment_params)
    end
end
