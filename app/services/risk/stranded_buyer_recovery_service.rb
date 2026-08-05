# frozen_string_literal: true

# Clears the platform blocks stranding a legitimate buyer, deterministically, so the admin CLI can
# recover them without a human reconstructing the rules by hand (gumroad-private#1640/#1746).
#
# The decision order is fixed: resolve every identifier the buyer's PROVEN checkouts have carried
# (a checkout email is unauthenticated, so same-email rows only count when the buyer's own card or
# account corroborates them — see Purchase::Blockable#corroborated_guest_purchases), refuse to
# touch anything that names an author, veto on any live chargeback, require the card-proven clean
# history the live block rules themselves respect, attribute which rule wrote the block, clear the
# person-bound rows, and verify per identifier that nothing active survived. Card-fingerprint rows
# stay when the issuer is still declining that card, and email_domain rows always stay — a domain
# block holds everyone at that domain, which is not this service's call to make.
#
#   Risk::StrandedBuyerRecoveryService.call(email: "buyer@example.com")                  # dry run
#   Risk::StrandedBuyerRecoveryService.call(email: "buyer@example.com", dry_run: false)  # clear
class Risk::StrandedBuyerRecoveryService
  class VerificationFailedError < StandardError; end
  class UnsafeClearError < StandardError; end

  # The in-app decline codes a PlatformBlock check writes on a checkout — a failure carrying one
  # is a buyer who actually hit our block, which is what gates the recovery email.
  BLOCK_ERROR_CODES = [
    PurchaseErrorCode::BLOCKED_BROWSER_GUID,
    PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN,
    PurchaseErrorCode::BLOCKED_IP_ADDRESS,
  ].freeze

  Result = Struct.new(:verdict, :reason, :attribution, :cleared, :skipped, :dry_run, keyword_init: true) do
    def to_h
      super.merge(cleared: cleared.map { serialize_block(_1) }, skipped: skipped.map { |block, why| serialize_block(block).merge(reason: why) })
    end

    def serialize_block(block)
      { object_type: block.object_type, object_value: block.object_value, blocked_at: block.blocked_at&.as_json }
    end
  end

  def self.call(email: nil, user_external_id: nil, dry_run: true)
    new(email:, user_external_id:, dry_run:).call
  end

  def initialize(email: nil, user_external_id: nil, dry_run: true)
    raise ArgumentError, "email or user_external_id is required" if email.blank? && user_external_id.blank?

    @email = email.presence&.strip&.downcase
    @user_external_id = user_external_id.presence
    @dry_run = dry_run
  end

  def call
    return result(:noop, :buyer_not_found) if user.nil? && candidate_purchases.empty?

    # Any row that names an author — a human admin OR the shared automation actor, which writes
    # confirmed-fraud blocks (chargeback count, EFW) — is a decision about this buyer, not a rule
    # that outlived itself. Only unattended rows (blocked_by nil) clear autonomously.
    return result(:noop, :no_active_blocks) if active_blocks.empty?

    authored_rows = active_blocks.select { |block| authored?(block) }
    return result(:escalate, :authored_block, skipped: authored_rows.map { [_1, :authored] }) if authored_rows.any?

    return result(:skip, :no_clean_payment_history) if clean_history_anchor.nil?

    # A live dispute is exactly what a block is for — the same veto the scan applies
    # (Risk::StrandedBuyerScanService#reject_disputed), re-checked here because recovery can be
    # invoked directly on any buyer, not just a scan candidate.
    return result(:skip, :unreversed_chargeback) if unreversed_chargeback?

    attribution = attribute_rule
    # The collapsed 7-day count is what the live velocity rules read; over threshold means a rule
    # still wants these rows and clearing them switches enforcement off mid-attack.
    return result(:skip, :velocity_rule_still_firing, attribution:) if attribution[:recent_distinct_cards] >= Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS

    # The guid velocity rule has NO window (Purchase::Blockable#ban_fraudulent_buyer_browser_guid!),
    # so all-time distinct failed cards the innocence anchor does not explain still arm it.
    return result(:skip, :velocity_rule_still_firing, attribution:) if attribution[:all_time_unexplained_cards] >= Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS

    clearable, withheld = partition_blocks
    return result(:noop, :nothing_clearable, attribution:, skipped: withheld) if clearable.empty?

    unless dry_run
      clear!(clearable)
      verify!(clearable)
      record_admin_comment(attribution, clearable)
      notify_buyer
    end

    result(:cleared, attribution[:rule], attribution:, cleared: clearable, skipped: withheld)
  end

  private
    attr_reader :dry_run

    def user
      @_user ||= if @user_external_id.present?
        User.find_by(external_id: @user_external_id)
      elsif @email.present?
        User.by_email(@email).first
      end
    end

    # The raw checkout footprint, bounded the same way unblock_buyer! bounds its widening. Raw
    # rows anchor innocence and corroboration only — identifiers are harvested from
    # #buyer_purchases, the corroborated subset.
    def candidate_purchases
      @_candidate_purchases ||= begin
        scope = if user.present? && @email.present?
          Purchase.where("purchaser_id = ? OR email = ?", user.id, @email)
        elsif user.present?
          Purchase.where("purchaser_id = ? OR email = ?", user.id, user.email)
        else
          Purchase.where(email: @email)
        end
        scope.order(id: :desc).limit(Purchase::Blockable::MAX_SIBLING_PURCHASES_FOR_UNBLOCK).to_a
      end
    end

    def account_purchases
      @_account_purchases ||= user.present? ? candidate_purchases.select { _1.purchaser_id == user.id } : []
    end

    # The identifiers that prove a same-email row is this buyer's: their account, or a card that
    # itself passes the clean-history bar. Same one-hop, fingerprint-only corroboration as
    # Purchase::Blockable#corroborated_guest_purchases — a guid never corroborates.
    def trusted_fingerprints
      @_trusted_fingerprints ||= (clean_history_anchors + account_purchases).map(&:charge_processor_fingerprint).compact_blank.to_set
    end

    # A card tester who typed this buyer's email at a guest checkout contributes rows here but no
    # proven fingerprint, so their guid/IP/card never enter the clearable set.
    def buyer_purchases
      @_buyer_purchases ||= (account_purchases + candidate_purchases.select { trusted_fingerprints.include?(_1.charge_processor_fingerprint) }).uniq
    end

    # Checkout paypal/gifter emails are typed-in third-party addresses, not the buyer's identity
    # (see Purchase::Blockable#blockable_values_for, widened_emails: false) — only the row's own
    # email and the account-owned purchaser_email count.
    def identifier_emails
      @_identifier_emails ||= buyer_purchases.flat_map { [_1.email, _1.purchaser_email] }
                                             .push(@email, user&.email)
                                             .compact_blank.map(&:downcase).uniq
    end

    def identifier_domains
      @_identifier_domains ||= identifier_emails.filter_map do |address|
        Mail::Address.new(address).domain
      rescue Mail::Field::IncompleteParseError
        nil
      end.uniq
    end

    def identifier_guids
      @_identifier_guids ||= buyer_purchases.filter_map { _1.browser_guid.presence }.uniq
    end

    def identifier_ips
      @_identifier_ips ||= buyer_purchases.filter_map { _1.ip_address.presence }.uniq
    end

    def identifier_fingerprints
      @_identifier_fingerprints ||= buyer_purchases.flat_map { [_1.stripe_fingerprint, _1.charge_processor_fingerprint] }
                                                   .compact_blank.uniq
    end

    def active_blocks
      @_active_blocks ||= begin
        pairs = {
          PlatformBlock::TYPES[:email] => identifier_emails,
          PlatformBlock::TYPES[:email_domain] => identifier_domains,
          PlatformBlock::TYPES[:browser_guid] => identifier_guids,
          PlatformBlock::TYPES[:ip_address] => identifier_ips,
          PlatformBlock::TYPES[:charge_processor_fingerprint] => identifier_fingerprints,
        }
        scopes = pairs.filter_map do |object_type, values|
          PlatformBlock.active.where(object_type:, object_value: values) if values.any?
        end
        scopes.any? ? scopes.reduce { |combined, scope| combined.or(scope) }.to_a : []
      end
    end

    # blocked_by nil is the only clearable authorship: the velocity rules write nil, while
    # GUMROAD_ADMIN_ID authors confirmed-fraud blocks (chargeback count, EFW) and humans author
    # decisions — both escalate.
    def authored?(block)
      block.blocked_by.present?
    end

    # Innocence is card-proven or it is nothing (see Purchase::Blockable#buyer_has_clean_payment_history?).
    # Tried per distinct fingerprint, newest first, because the stranded buyer's newest card is often
    # the reissued one with no history yet — the OLD card is what proves them.
    ANCHOR_FINGERPRINT_LIMIT = 10

    def clean_history_anchors
      @_clean_history_anchors ||= candidate_purchases.select { _1.stripe_fingerprint.present? }
                                                     .sort_by { -_1.id }
                                                     .uniq(&:stripe_fingerprint)
                                                     .first(ANCHOR_FINGERPRINT_LIMIT)
                                                     .select(&:buyer_has_clean_payment_history?)
    end

    def clean_history_anchor
      clean_history_anchors.first
    end

    # The exact complement of the not_chargedback_or_chargedback_reversed scope clean history
    # counts, mirroring Risk::StrandedBuyerScanService#reject_disputed.
    def unreversed_chargeback?
      scope = Purchase.where.not(chargeback_date: nil)
                      .where("purchases.flags & :bit = 0", bit: Purchase.flag_mapping["flags"][:chargeback_reversed])
      emails = [@email, user&.email].compact_blank
      scope = if user.present?
        scope.where("purchaser_id = ? OR email IN (?)", user.id, emails)
      else
        scope.where(email: emails)
      end
      scope.exists?
    end

    # Which rule wrote the block, read from the same counts the live rules read. The raw-vs-collapsed
    # pair is what exposes PayPal wallet inflation: one wallet mints a fresh billing-agreement token
    # (stripe_fingerprint LIKE 'B-%') per attempt, so raw tokens trip a four-card rule that the
    # card_visual-collapsed count — the identity Purchase.distinct_card_count keys wallets on — never
    # would.
    def attribute_rule
      recent = countable_failures.where(created_at: Purchase::Blockable::CARD_TESTING_WATCH_PERIOD.ago..)
      recent_collapsed = Purchase.distinct_card_count(recent)
      raw_recent = recent.distinct.count(:stripe_fingerprint)
      all_time_collapsed = Purchase.distinct_card_count(countable_failures)
      all_time_unexplained = Purchase.distinct_card_count(countable_failures.where.not(stripe_fingerprint: trusted_fingerprints.to_a))
      threshold = Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS

      rule = if recent_collapsed >= threshold
        :recent_card_testing_velocity
      elsif raw_recent >= threshold
        :paypal_wallet_inflation
      elsif all_time_collapsed >= threshold
        :browser_guid_all_time_velocity
      else
        :single_decline_auto_block
      end

      {
        rule:,
        recent_distinct_cards: recent_collapsed,
        recent_raw_fingerprints: raw_recent,
        all_time_distinct_cards: all_time_collapsed,
        all_time_unexplained_cards: all_time_unexplained,
        paypal_collapse_applied: raw_recent > recent_collapsed,
      }
    end

    def countable_failures
      scope = Purchase.countable_card_testing_failures
      if identifier_guids.any?
        scope.where("email IN (?) OR browser_guid IN (?)", identifier_emails, identifier_guids)
      else
        scope.where(email: identifier_emails)
      end
    end

    # Person-bound rows clear. A card the issuer is still refusing stays blocked — the block is not
    # what is declining it. An email_domain row always stays: it holds everyone at that domain, an
    # unbounded blast radius no single buyer's innocence can vouch for.
    def partition_blocks
      clearable = []
      withheld = []
      active_blocks.each do |block|
        if block.email_domain?
          withheld << [block, :domain_wide_block]
        elsif block.charge_processor_fingerprint? && card_still_declining?(block.object_value)
          withheld << [block, :card_still_declining_at_issuer]
        else
          clearable << block
        end
      end
      [clearable, withheld]
    end

    # Matches both columns because a PayPal wallet's block value is card_visual (the attested payer
    # email), not a Stripe fingerprint — see Purchase#charge_processor_fingerprint.
    def card_still_declining?(value)
      matching = Purchase.where("stripe_fingerprint = :value OR card_visual = :value", value:)
      last_fraud_decline = matching.failed
                                   .where(
                                     "stripe_error_code IN (:codes) OR error_code IN (:codes)",
                                     codes: PurchaseErrorCode::AUTO_BLOCK_ERROR_CODES
                                   )
                                   .maximum(:created_at)
      return false if last_fraud_decline.nil?

      last_success = matching.successful.maximum(:created_at)
      last_success.nil? || last_success < last_fraud_decline
    end

    # Every guard re-asserted per row at the write, against a fresh read — the batch decision is a
    # snapshot a concurrent admin block or re-block can invalidate (same pattern as
    # AlertOnStaleBlocksHoldingEstablishedBuyersJob and Onetime::ClearMistakenBuyerBlocks).
    def clear!(blocks)
      raise UnsafeClearError, "buyer no longer has clean payment history" unless clean_history_anchor.buyer_has_clean_payment_history?

      expected = blocks.to_h { [_1.id, [_1.object_type, _1.object_value, _1.blocked_at]] }
      blocks.each do |block|
        snapshot_type, snapshot_value, snapshot_blocked_at = expected[block.id]
        block.reload
        raise UnsafeClearError, "block #{block.id} changed identity underneath the run" if [block.object_type, block.object_value] != [snapshot_type, snapshot_value]
        raise UnsafeClearError, "block #{block.id} now names an author" if authored?(block)
        next if block.blocked_at.nil? || (block.expires_at.present? && block.expires_at <= Time.current)
        # A fresh blocked_at is a re-block the decision never saw — a live rule fired between the
        # snapshot and this write, and wiping it would switch enforcement off mid-attack.
        raise UnsafeClearError, "block #{block.id} was re-blocked underneath the run" if block.blocked_at != snapshot_blocked_at

        block.unblock!
      end
    end

    def verify!(blocks)
      still_active = blocks.map { [_1.object_type, _1.object_value] }.uniq.sum do |object_type, object_value|
        PlatformBlock.active.where(object_type:, object_value:).count
      end
      raise VerificationFailedError, "#{still_active} block(s) still active after clearing" if still_active.positive?
    end

    def record_admin_comment(attribution, cleared)
      rows = cleared.map { "#{_1.object_type} #{_1.object_value}" }.join(", ")
      content = "Stranded-buyer recovery cleared #{cleared.size} platform block(s) [#{rows}]. " \
                "Attributed rule: #{attribution[:rule]} " \
                "(7d distinct cards: #{attribution[:recent_distinct_cards]}, raw fingerprints: #{attribution[:recent_raw_fingerprints]}, " \
                "all-time distinct cards: #{attribution[:all_time_distinct_cards]})."

      if user.present?
        User::CreateAdminCommentService.new(
          user:,
          content:,
          idempotency_key: "stranded_buyer_recovery:#{Time.current.to_date}:#{cleared.map(&:id).sort.join(",")}"
        ).perform
      else
        clean_history_anchor.comments.create!(content:, comment_type: Comment::COMMENT_TYPE_NOTE, author_id: GUMROAD_ADMIN_ID)
      end
    end

    # Only a buyer whose newest recent failure actually hit our block gets the email — an ordinary
    # decline is not something this run resolved, and a years-stale block cleared by a sweep is not
    # an invitation anyone is waiting for.
    RECENT_FAILURE_WINDOW = 60.days

    def notify_buyer
      failed = buyer_purchases.select { _1.failed? && _1.created_at >= RECENT_FAILURE_WINDOW.ago && _1.email.present? }.max_by(&:created_at)
      return if failed.nil? || BLOCK_ERROR_CODES.exclude?(failed.error_code)

      CustomerLowPriorityMailer.blocked_purchase_resolved(failed.id).deliver_later(queue: "low")
    end

    def result(verdict, reason, attribution: nil, cleared: [], skipped: [])
      Result.new(verdict:, reason:, attribution:, cleared:, skipped:, dry_run:)
    end
end
