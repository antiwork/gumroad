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

  # Failures the buyer had no part in, so they cannot be evidence of card testing.
  #
  # Split by the column each lands in: our own outage codes are written to `error_code`, while a
  # card decline is written to `stripe_error_code` (and leaves `error_code` NULL — see
  # #failure_code, which reads `stripe_error_code || error_code`).
  #
  # The outage codes mean our call to the processor never completed, so the card was never
  # contacted and the attempt says nothing about it. Counting them lets a processor incident
  # manufacture its own fraud evidence against everyone who retried during it.
  CARD_TESTING_UNCOUNTED_ERROR_CODES = [
    PurchaseErrorCode::STRIPE_UNAVAILABLE,
    PurchaseErrorCode::PAYPAL_UNAVAILABLE,
    PurchaseErrorCode::PROCESSING_ERROR,
    PurchaseErrorCode::PROCESSOR_INVALID_REQUEST,
  ].freeze
  private_constant :CARD_TESTING_UNCOUNTED_ERROR_CODES

  # Card errors carrying no signal about the card, spelled the way StripeErrorHandler composes
  # them ("card_declined" + "_" + decline_code) plus Braintree's own network code.
  #
  # Only failures the processor could not answer about belong here. A decline the ISSUER answered
  # stays counted, insufficient_funds included: the issuer accepted the number, expiry and CVC and
  # refused only on balance, which is the positive validity signal a tester is buying — and since
  # the attacker picks the amount, they can push live stolen cards into it at will. Exempting it
  # would turn the rule's blind spot into a card-validation oracle, while doing nothing for the
  # stranded buyer this exists for: one person retrying one card is one fingerprint and can never
  # reach a four-card threshold.
  CARD_TESTING_UNCOUNTED_DECLINE_CODES = [
    "card_declined_processing_error",
    "processing_error",
    "3000", # Braintree: Processor Network Unavailable - Try Again
  ].freeze
  private_constant :CARD_TESTING_UNCOUNTED_DECLINE_CODES

  MAX_BUYER_CHARGEBACKS_BEFORE_BLOCK = 5

  class_methods do
    # Shared with Onetime::ClearMistakenBuyerBlocks, which must reproduce these rules exactly: if
    # it counts differently it clears a block a live rule still wants, switching enforcement off
    # for that identifier.
    def countable_card_testing_failures
      Purchase.failed.with_stripe_fingerprint
              .where(charge_processor_id: [StripeChargeProcessor.charge_processor_id,
                                           PaypalChargeProcessor.charge_processor_id])
              .where("(stripe_error_code NOT IN (?) OR stripe_error_code IS NULL)", CARD_TESTING_UNCOUNTED_DECLINE_CODES)
              .where("(error_code NOT IN (?) OR error_code IS NULL)", CARD_TESTING_UNCOUNTED_ERROR_CODES)
    end

    # PayPal writes a per-transaction billing-agreement token into stripe_fingerprint, so one
    # wallet mints a fresh "card" on every attempt and four retries on a single funding source
    # trip a four-card rule. Collapse each PayPal wallet to one unit of evidence — somebody
    # cycling several stolen wallets still accumulates one per wallet — while every Stripe
    # fingerprint stays its own card.
    #
    # Keyed on card_visual, which holds the payer email PayPal attested for the order, NOT
    # purchases.email: the buyer types that one, so keying on it would let an attacker cycle any
    # number of stolen wallets under a single checkout email and count as one forever. A wallet
    # with no attested payer is not provably the same wallet as any other, so it counts on its
    # own token rather than merging into one free unit.
    #
    # Returns at most MAX_NUMBER_OF_FAILED_FINGERPRINTS — every caller only compares against
    # that threshold. Deduplicating in SQL and stopping at the threshold is what bounds the scan
    # (the guid rule has no time window, and this runs inside the purchase state-machine
    # transition): a newest-N row cap before the dedup made the count depend on retry order, so
    # a tester could flush an older card out of the window by retrying fewer cards more often.
    def distinct_card_count(relation)
      paypal_id = ActiveRecord::Base.connection.quote(PaypalChargeProcessor.charge_processor_id)
      identity = <<~SQL.squish
        CASE WHEN charge_processor_id = #{paypal_id}
             THEN CONCAT('wallet:', COALESCE(NULLIF(card_visual, ''), CONCAT('token:', stripe_fingerprint)))
             ELSE CONCAT('card:', stripe_fingerprint)
        END
      SQL
      relation.distinct.limit(MAX_NUMBER_OF_FAILED_FINGERPRINTS).pluck(Arel.sql(identity)).size
    end
  end

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
    # The typed-in addresses on sibling rows, which the unblock deliberately does not clear (see
    # #blockable_values_for). Reported for the same reason as the uncorroborated guest rows: a
    # refusal the caller cannot see reads as a successful unblock while the buyer is still held.
    withheld_sibling_emails = blockable_values_for(sibling_buyer_purchases)[PlatformBlock::TYPES[:email]].to_a -
                              buyer_blockable_values[PlatformBlock::TYPES[:email]].to_a
    scopes << PlatformBlock.active.email.where(object_value: withheld_sibling_emails) if withheld_sibling_emails.any?
    return PlatformBlock.none if scopes.empty?

    scopes.reduce { |combined, scope| combined.or(scope) }
  end

  # How far back to look for the buyer's latest processor attempt. Radar's own velocity predicates
  # run over 24h, so an older charge says nothing about whether a rule is holding them now.
  PROCESSOR_REFUSAL_WINDOW = 24.hours

  # Radar value lists that back our own PlatformBlocks. A refusal on a rule whose predicate reads
  # one of these is the block support just cleared, not an independent limit.
  PLATFORM_BLOCK_VALUE_LISTS = %w[gumroad_blocked_emails gumroad_blocked_cards].freeze

  # An informational read on an admin request that has already committed its unblock, so it gets a
  # tight budget and never retries: a slow processor must not turn a done unblock into a timeout.
  #
  # Passed as a StripeClient, never as per-request opts: stripe-ruby forwards any opts key outside
  # `Util::OPTS_USER_SPECIFIED` as an HTTP header, so an Integer timeout raises `NoMethodError:
  # undefined method 'strip' for an instance of Integer` before the request leaves the process —
  # which the rescue below then reports as "could not read the processor outcome" on every call.
  PROCESSOR_REFUSAL_READ_OPTS = { read_timeout: 5, open_timeout: 2, max_network_retries: 0 }.freeze

  # A refusal can sit behind newer attempts that failed for unrelated reasons (an issuer decline, a
  # card the buyer mistyped), so the newest attempt alone is not enough. These bound the scan: the
  # buyer in gumroad-private#1739 made 16 attempts in the window, and an unblock that has already
  # committed cannot spend that many round trips.
  PROCESSOR_REFUSAL_MAX_READS = 4
  PROCESSOR_REFUSAL_TIME_BUDGET = 8.seconds

  # Rows to pull before picking the ones to read. A card-testing email can have thousands of attempts
  # in the window, and loading them all to learn "more than four" is wasted work on a request whose
  # unblock has already committed. Hitting this bound counts as capped: there may be more behind it.
  PROCESSOR_REFUSAL_MAX_SCAN = 40

  # Both timeout phases spend the same budget, so a read needs a second for each of them to be worth
  # starting; with less left than this the attempt is counted unread instead.
  PROCESSOR_REFUSAL_MIN_READ_SECONDS = 2

  # Whether the PROCESSOR is still refusing this buyer on one of our own risk rules, read from the
  # processor rather than inferred from our rows.
  #
  # This has to come from Stripe. A refusal on a Radar VELOCITY predicate is computed over Stripe's
  # own view of the last 24h, so there is no value-list item to delete and clearing every
  # PlatformBlock leaves it standing. Our purchase rows cannot stand in for it: an attempt that dies
  # before the card is authorised stores no `stripe_fingerprint` at all, so a buyer who cycled four
  # payment methods can look like one card to us (gumroad-private#1739 — 14 of 16 attempts had a
  # NULL fingerprint).
  #
  # `reason == "rule"` alone cannot carry the message, because our email/card PlatformBlocks are
  # ALSO enforced at Stripe as user-defined value-list rules and refuse with the identical
  # type/reason pair. Verified live on the #1739 buyer: the refusing rule was
  # `:email: IN @gumroad_blocked_emails`, the very block being cleared. So the rule's predicate
  # decides which of the two stories the agent is told — see `:kind` below.
  #
  # Only platform-account charges are considered: a refusal on a creator's own Connect account came
  # from THEIR Radar rules, which we neither set nor can lift.
  #
  # Returns nil only when the whole window was read and nothing is holding them; a scan that ran out
  # of reads or budget returns `incomplete` instead, because a nil there is indistinguishable from
  # "clean" to the callers and that silence is the bug this method exists to end.
  def processor_rule_refusal
    scanned = Purchase.where(email:)
                      .where(created_at: PROCESSOR_REFUSAL_WINDOW.ago..)
                      .where(charge_processor_id: StripeChargeProcessor.charge_processor_id)
                      .where.not(stripe_transaction_id: nil)
                      .order(created_at: :desc)
                      .limit(PROCESSOR_REFUSAL_MAX_SCAN)
                      .includes(:merchant_account)
                      .to_a
    eligible = scanned.reject { |purchase| purchase.merchant_account&.is_a_stripe_connect_account? }
    candidates = eligible.first(PROCESSOR_REFUSAL_MAX_READS)

    # A full scan may be hiding eligible rows behind the bound, so it counts as capped too.
    capped = eligible.size > candidates.size || scanned.size == PROCESSOR_REFUSAL_MAX_SCAN

    # Ordered before the empty-candidates exit: a page that is entirely Connect rows leaves every
    # eligible attempt behind the bound, and a bare nil there is the truncated-scan-reads-as-clean
    # silence this method exists to end.
    if candidates.empty?
      return { incomplete: true, truncated_by: :read_cap } if capped

      return
    end

    ran_out_of_time = false
    deadline = Time.current + PROCESSOR_REFUSAL_TIME_BUDGET

    candidates.each do |candidate|
      # Checked BEFORE the call, not after: each read carries its own timeout, so a post-call check
      # lets the budget overrun by a whole read on a request whose unblock has already committed.
      remaining = (deadline - Time.current).floor
      if remaining < PROCESSOR_REFUSAL_MIN_READ_SECONDS
        ran_out_of_time = true
        break
      end

      # Clamped together, because a connect and a read both spend this budget: leaving open_timeout
      # at its default lets a late read outlive the deadline by the whole connect phase.
      open_timeout = [PROCESSOR_REFUSAL_READ_OPTS[:open_timeout], remaining - 1].min
      read_client = Stripe::StripeClient.new(
        PROCESSOR_REFUSAL_READ_OPTS.merge(
          open_timeout:,
          read_timeout: [PROCESSOR_REFUSAL_READ_OPTS[:read_timeout], remaining - open_timeout].min
        )
      )
      charge = Stripe::Charge.retrieve({ id: candidate.stripe_transaction_id, expand: %w[outcome.rule] },
                                       { client: read_client })
      outcome = charge["outcome"] || {}

      # A later authorised attempt means the buyer already got through, so an earlier refusal in the
      # window is spent — stop rather than warning about a rule that is no longer holding them.
      return if outcome["type"] == "authorized"

      if outcome["type"] == "blocked" && outcome["reason"] == "rule"
        rule = outcome["rule"]
        predicate = rule.is_a?(String) ? nil : rule&.[]("predicate")

        return {
          kind: value_list_predicate?(predicate) ? :platform_block : :velocity_rule,
          charge_id: candidate.stripe_transaction_id,
          network_status: outcome["network_status"],
          risk_level: outcome["risk_level"],
          seller_message: outcome["seller_message"],
          predicate:,
          attempted_at: candidate.created_at,
        }
      end
    end

    # Reads left unmade mean an older refusal in the window may still stand. The two exits get
    # different copy because the agent's next move differs: a capped scan has attempts we never
    # looked at, a timed-out one may have nothing left to look at and just needs re-running.
    #
    # Time-out wins when a slow scan hits both, because then reads were also left unmade and a
    # re-run really can read further — and that copy already tells the agent to check Stripe too,
    # so it loses nothing the cap copy would have said.
    return { incomplete: true, truncated_by: :time_budget } if ran_out_of_time
    return { incomplete: true, truncated_by: :read_cap } if capped

    nil
  rescue StandardError => e
    # The unblock has already committed, so this read must never raise: report that the check could
    # not run rather than either failing the unblock or returning a nil that reads as "not blocked".
    Rails.logger.info("processor_rule_refusal: could not read charge for purchase #{id}: #{e.message}")
    { error: "could not read the processor outcome" }
  end

  # Copy for the two admin surfaces, kept here so they cannot drift apart.
  def processor_rule_refusal_note(refusal)
    return if refusal.blank?
    return "Could not check whether Stripe is still refusing this buyer — retry the check before promising anything." if refusal[:error].present?
    if refusal[:incomplete].present?
      if refusal[:truncated_by] == :time_budget
        return "Checked the buyer's most recent Stripe attempts and none of them was refused by our " \
               "rules, but the check ran out of time before reading them all — re-run it, and if the " \
               "buyer still fails, inspect their recent charges in Stripe before promising anything."
      end

      return "Checked the buyer's most recent Stripe attempts and none of them was refused by our " \
             "rules, but there were more attempts in the last day than this check reads — if the " \
             "buyer still fails, inspect their recent charges in Stripe before promising anything."
    end

    case refusal[:kind]
    when :platform_block
      "Stripe's latest refusal (#{refusal[:charge_id]}) was the block just cleared, not a separate " \
        "limit. Radar picks the removal up within a few minutes — have the buyer retry shortly."
    else
      "Stripe is still refusing this buyer on one of our risk rules (charge #{refusal[:charge_id]}, " \
        "#{refusal[:network_status]}), and there is nothing left for us to lift: it clears on its " \
        "own about a day after their first attempt, so do not promise an immediate retry."
    end
  end

  private def value_list_predicate?(predicate)
    return false if predicate.blank?

    PLATFORM_BLOCK_VALUE_LISTS.any? { |list| predicate.include?(list) }
  end

  private def buyer_blockable_values
    @_buyer_blockable_values ||= blockable_values_for([self, *sibling_buyer_purchases], extra_fingerprints: [recent_stripe_fingerprint], widened_emails: false)
  end

  # `widened_emails: false` keeps a sibling row's typed-in addresses out of the unblock set, and
  # is the default for anything that CLEARS blocks. A checkout, PayPal or gifter email is
  # unauthenticated text on a row — the buyer can put anyone's address there, and a gift row
  # legitimately carries the recipient's. Siblings are selected by `purchaser_id`, so widening
  # those would let an unblock of this buyer deactivate a PlatformBlock earned by a different
  # person whose address happens to sit on one of the buyer's rows. Only `purchaser_email` is
  # account-owned (it is delegated to the purchaser record), so that is the one a sibling
  # contributes; the acting row's own addresses stay in scope because the admin is acting on it.
  #
  # Guids and card fingerprints ARE widened from siblings, for the reason #unblock_buyer! gives:
  # they name a browser and a physical card, not a string somebody typed.
  #
  # A browser can still be shared, so clearing a sibling guid can lift a block a co-user of that
  # browser earned. Accepted deliberately: the co-user's person-bound blocks (email, card) stay
  # put, renewed abuse re-earns the guid block via the velocity checks, and withholding sibling
  # guids is exactly the never-expiring stranded-block problem this widening exists to fix.
  private def blockable_values_for(purchases, extra_fingerprints: [], widened_emails: true)
    guids = Set.new
    emails = Set.new
    fingerprints = Set.new

    purchases.each do |purchase|
      guids << purchase.browser_guid
      emails.merge(
        if widened_emails || purchase == self
          [purchase.email, purchase.paypal_email, purchase.gifter_email, purchase.purchaser_email]
        else
          [purchase.purchaser_email]
        end
      )
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

    chargeback_stats = seller.lost_chargebacks_for_payout_gate
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
        content: "Payouts automatically paused due to chargeback rate (#{chargeback_volume_percentage}) exceeding #{User::MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS}% volume over the last #{User::PAYOUT_CHARGEBACK_RATE_WINDOW.inspect}.",
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
        refund_policy.update!(
          max_refund_period_in_days: User::ENFORCED_MIN_REFUND_PERIOD_IN_DAYS,
          fine_print: nil,
        )
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

      recent_failures = countable_card_testing_failures.where(browser_guid:)
      return if distinct_card_count(recent_failures) < MAX_NUMBER_OF_FAILED_FINGERPRINTS
      return if buyer_has_clean_checkout_history?

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
    # distinct cards have failed — unless the sprayer has clean checkout history
    # (#buyer_has_clean_checkout_history?), where only the per-card, IP and per-product limits apply.
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
      recent_failures = countable_card_testing_failures
                          .where("email = ? or browser_guid = ?", email, browser_guid)
                          .where(created_at: CARD_TESTING_WATCH_PERIOD.ago..)

      return if distinct_card_count(recent_failures) < MAX_NUMBER_OF_FAILED_FINGERPRINTS
      return if buyer_has_clean_checkout_history?

      block_buyer!
    end

    # The velocity rules count DISTINCT fingerprints as a proxy for "how many different cards has
    # this person tried". Signal-free failures break that proxy: see CARD_TESTING_UNCOUNTED_*.
    #
    # The two lists are matched against different columns — a card decline writes
    # stripe_error_code and leaves error_code NULL, while our own outage codes write error_code
    # (see #failure_code, which reads `stripe_error_code || error_code`). Both comparisons must
    # survive NULL: `col NOT IN (...)` evaluates to NULL, not TRUE, when col is NULL, which would
    # silently drop every real decline from the count.
    #
    # Deliberately NOT scoped to Stripe: PayPal rows still count toward the buyer and IP rules,
    # which are the only thing standing between us and somebody cycling stolen PayPal accounts.
    # Their per-transaction token problem is fixed by counting them per wallet, not by hiding them.
    #
    # Restricted to the two processors that write a fingerprint we understand. A row with no
    # charge_processor_id is not evidence about any card, and counting it made ordinary test and
    # legacy rows trip the rule.
    def countable_card_testing_failures
      Purchase.countable_card_testing_failures
    end

    def distinct_card_count(relation)
      Purchase.distinct_card_count(relation)
    end

    # The velocity rules' version of #buyer_has_clean_payment_history?, which cannot be reused here:
    # the trigger IS several never-seen cards failing, so card-keyed history is empty by
    # construction. Provenance comes from the browser and the email together — either alone is
    # claimable, since an unauthenticated checkout types whatever address it likes and a guid is a
    # cookie a shared or reset device hands to the next person.
    def buyer_has_clean_checkout_history?
      return false if email.blank? || browser_guid.blank?

      Purchase.successful.non_free.not_fully_refunded.not_chargedback_or_chargedback_reversed
              .where(created_at: ..MIN_PURCHASE_AGE_FOR_CLEAN_HISTORY.ago)
              .where.not(id:)
              .where(email:, browser_guid:)
              .limit(MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY)
              .count >= MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY
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

      # Excludes the seller testing their own paid flow (gumroad-private#1755): several
      # self-purchases on new cards is the documented way to verify checkout, and it should not
      # arm a threshold meant for a stranger card-testing the storefront. Only a confirmed
      # `purchaser_id` match proves the seller made the purchase — a guest checkout's typed-in
      # email is unauthenticated and a card tester can set it to the seller's own address to
      # dodge the threshold entirely, so email alone must never exempt a row.
      recent_failures = countable_card_testing_failures
                          .where("ip_address = ?", ip_address)
                          .where(created_at: CARD_TESTING_IP_ADDRESS_WATCH_PERIOD.ago..)
                          .where("purchaser_id IS NULL OR purchaser_id != ?", seller.id)

      return if distinct_card_count(recent_failures) < MAX_NUMBER_OF_FAILED_FINGERPRINTS

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
