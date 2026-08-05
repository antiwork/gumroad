# frozen_string_literal: true

# Clears the platform blocks stranding a legitimate buyer, deterministically, so the admin CLI can
# recover them without a human reconstructing the rules by hand (gumroad-private#1640/#1746).
#
# The decision order is fixed: resolve every identifier the buyer's checkouts have carried, refuse
# to touch anything a human wrote, require the card-proven clean history the live block rules
# themselves respect, attribute which rule wrote the block, clear the person-bound rows, and verify
# per identifier that nothing active survived. Card-fingerprint rows stay when the issuer is still
# declining that card — clearing them invites a retry the issuer will refuse.
#
#   Risk::StrandedBuyerRecoveryService.call(email: "buyer@example.com")                  # dry run
#   Risk::StrandedBuyerRecoveryService.call(email: "buyer@example.com", dry_run: false)  # clear
class Risk::StrandedBuyerRecoveryService
  class VerificationFailedError < StandardError; end
  class UnsafeClearError < StandardError; end

  # Only identifiers that are this buyer's alone — email and browser_guid are not realistically
  # shared with an unrelated abuser. email_domain and ip_address are NOT here: one buyer's
  # card-proven clean history says nothing about every other actor sharing that domain or IP
  # (NAT, corporate mail relay, shared office network), so clearing those automatically would
  # remove enforcement against people this buyer's history never vouched for. They fall through
  # to withheld and wait on a human.
  CLEARABLE_TYPES = [
    PlatformBlock::TYPES[:browser_guid],
    PlatformBlock::TYPES[:email],
  ].freeze

  # Buyer-bound in the sense that clearing helps THIS buyer, but with a blast radius wide enough
  # that automation shouldn't decide alone — surfaced to a human instead of auto-cleared.
  SHARED_RADIUS_TYPES = [
    PlatformBlock::TYPES[:email_domain],
    PlatformBlock::TYPES[:ip_address],
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
    return result(:noop, :buyer_not_found) if user.nil? && buyer_purchases.empty?
    return result(:noop, :no_active_blocks) if active_blocks.empty?

    # Any row a human other than the automation actor wrote is a decision about this buyer, not a
    # rule that outlived itself — nothing is touched, including rows the automation could clear.
    human_rows = active_blocks.select { |block| foreign_authored?(block) }
    return result(:escalate, :human_authored_block, skipped: human_rows.map { [_1, :human_authored] }) if human_rows.any?

    return result(:skip, :no_clean_payment_history) if clean_history_anchor.nil?

    attribution = attribute_rule
    # The collapsed 7-day count is what the live velocity rules read; over threshold means a rule
    # still wants these rows and clearing them switches enforcement off mid-attack.
    return result(:skip, :velocity_rule_still_firing, attribution:) if attribution[:recent_distinct_cards] >= Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS

    clearable, withheld = partition_blocks
    return result(:noop, :nothing_clearable, attribution:, skipped: withheld) if clearable.empty?

    unless dry_run
      # Wrapped so a mid-batch failure (concurrent re-block, reload mismatch, verification miss)
      # rolls back every unblock! in this call instead of leaving enforcement partially removed
      # with no admin comment recording what happened.
      ActiveRecord::Base.transaction do
        clear!(clearable)
        verify!(clearable)
        record_admin_comment(attribution, clearable)
      end
      notify_buyer(withheld)
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

    # The buyer's checkout footprint, bounded the same way unblock_buyer! bounds its widening.
    def buyer_purchases
      @_buyer_purchases ||= begin
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

    def identifier_emails
      @_identifier_emails ||= buyer_purchases.flat_map { [_1.email, _1.paypal_email, _1.gifter_email, _1.purchaser_email] }
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

    def foreign_authored?(block)
      block.blocked_by.present? && block.blocked_by != GUMROAD_ADMIN_ID
    end

    # Innocence is card-proven or it is nothing (see Purchase::Blockable#buyer_has_clean_payment_history?).
    # Tried per distinct fingerprint, newest first, because the stranded buyer's newest card is often
    # the reissued one with no history yet — the OLD card is what proves them.
    ANCHOR_FINGERPRINT_LIMIT = 10

    def clean_history_anchor
      return @_clean_history_anchor if defined?(@_clean_history_anchor)

      candidates = buyer_purchases.select { _1.stripe_fingerprint.present? }
                                  .sort_by { -_1.id }
                                  .uniq(&:stripe_fingerprint)
                                  .first(ANCHOR_FINGERPRINT_LIMIT)
      @_clean_history_anchor = candidates.find(&:buyer_has_clean_payment_history?)
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

    # Person-bound rows clear; a card the issuer is still refusing stays blocked, because the block
    # is not what is declining it and clearing it reads as "fixed" to a buyer whose retry will fail.
    # Shared-radius rows (domain/IP) never auto-clear — see SHARED_RADIUS_TYPES.
    def partition_blocks
      clearable = []
      withheld = []
      active_blocks.each do |block|
        if CLEARABLE_TYPES.include?(block.object_type)
          clearable << block
        elsif SHARED_RADIUS_TYPES.include?(block.object_type)
          withheld << [block, :shared_identifier_needs_human_review]
        elsif block.charge_processor_fingerprint? && card_still_declining?(block.object_value)
          withheld << [block, :card_still_declining_at_issuer]
        else
          clearable << block
        end
      end
      [clearable, withheld]
    end

    def card_still_declining?(fingerprint)
      last_fraud_decline = Purchase.failed
                                   .where(stripe_fingerprint: fingerprint)
                                   .where(
                                     "stripe_error_code IN (:codes) OR error_code IN (:codes)",
                                     codes: PurchaseErrorCode::AUTO_BLOCK_ERROR_CODES
                                   )
                                   .maximum(:created_at)
      return false if last_fraud_decline.nil?

      last_success = Purchase.successful.where(stripe_fingerprint: fingerprint).maximum(:created_at)
      last_success.nil? || last_success < last_fraud_decline
    end

    # Every guard re-asserted per row at the write, against a fresh read — the batch decision is a
    # snapshot a concurrent admin block or re-block can invalidate (same pattern as
    # AlertOnStaleBlocksHoldingEstablishedBuyersJob and Onetime::ClearMistakenBuyerBlocks).
    def clear!(blocks)
      raise UnsafeClearError, "buyer no longer has clean payment history" unless clean_history_anchor.buyer_has_clean_payment_history?

      expected = blocks.to_h { [_1.id, [_1.object_type, _1.object_value]] }
      blocks.each do |block|
        block.reload
        raise UnsafeClearError, "block #{block.id} changed identity underneath the run" if expected[block.id] != [block.object_type, block.object_value]
        raise UnsafeClearError, "block #{block.id} is now human-authored" if foreign_authored?(block)
        next if block.blocked_at.nil? || (block.expires_at.present? && block.expires_at <= Time.current)

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

    # Only a buyer who actually hit the block recently gets the email — a years-stale block cleared
    # by a sweep is not an invitation anyone is waiting for.
    RECENT_FAILURE_WINDOW = 60.days

    def notify_buyer(withheld)
      # A retained card-fingerprint block means THIS card is still guaranteed to fail — telling the
      # buyer to retry sends them straight into another decline. Domain/IP holds are informational
      # (they gate other people's blocks, not this buyer's own retry), so they don't suppress the email.
      return if withheld.any? { |block, reason| reason == :card_still_declining_at_issuer }

      failed = buyer_purchases.select { _1.failed? && _1.created_at >= RECENT_FAILURE_WINDOW.ago && _1.email.present? }.max_by(&:created_at)
      return if failed.nil?

      CustomerLowPriorityMailer.blocked_purchase_resolved(failed.id).deliver_later(queue: "low")
    end

    def result(verdict, reason, attribution: nil, cleared: [], skipped: [])
      Result.new(verdict:, reason:, attribution:, cleared:, skipped:, dry_run:)
    end
end
