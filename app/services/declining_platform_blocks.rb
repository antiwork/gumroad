# frozen_string_literal: true

# For each failed purchase, the active platform block that declined it — absent when no such block
# is active any more, which is what makes a purchase's staleness reportable.
#
# Shared by AlertOnBlockedEstablishedSubscribersJob and AlertOnBlockedEstablishedBuyersJob so the
# two reports cannot disagree about whether someone is still blocked, or about which of several
# blocks did the declining.
#
#   DecliningPlatformBlocks.new(failures).call # => { purchase_id => PlatformBlock }
class DecliningPlatformBlocks
  def initialize(failures)
    @failures = failures
  end

  # Three queries for the whole set rather than one per purchase.
  def call
    guid_purchases, remaining = failures.partition { |purchase| purchase.error_code == PurchaseErrorCode::BLOCKED_BROWSER_GUID }
    ip_purchases, domain_purchases = remaining.partition { |purchase| purchase.error_code == PurchaseErrorCode::BLOCKED_IP_ADDRESS }

    guids = guid_purchases.filter_map { |purchase| purchase.browser_guid.presence }.uniq
    ips = ip_purchases.filter_map { |purchase| purchase.ip_address.presence }.uniq
    domains_by_purchase = domain_purchases.index_with { |purchase| blocked_domain_candidates(purchase) }

    # Each lookup mirrors the check that declined this purchase, and the checks do NOT agree on
    # type scope. Purchase::Risk#check_for_past_blocked_guids and #check_for_past_fraudulent_ips
    # both go through a match on object_value alone — a value stored under any type declines the
    # purchase, so scoping either lookup here would find nothing and drop the buyer from the report
    # entirely. Only the domain check runs through a scoped lookup (AttributeBlockable), so that one
    # stays scoped to :email_domain.
    #
    # The domain lookup also resolves by candidate order rather than by date, because
    # blocked_by_email_domain_if_fraudulent_transaction? short-circuits on the first of the four
    # domains that is blocked; that row holds this purchase even when another candidate carries an
    # older block.
    guid_blocks = guids.any? ? earliest_blocks_by_value(guids) : {}
    ip_blocks = ips.any? ? earliest_blocks_by_value(ips) : {}
    all_domains = domains_by_purchase.values.flatten.uniq
    domain_blocks = all_domains.any? ? earliest_blocks_by_value(all_domains, object_type: PlatformBlock::TYPES[:email_domain]) : {}

    blocks = {}
    guid_purchases.each { |purchase| blocks[purchase.id] = guid_blocks[purchase.browser_guid&.downcase] }
    ip_purchases.each { |purchase| blocks[purchase.id] = ip_blocks[purchase.ip_address&.downcase] }
    domain_purchases.each do |purchase|
      declining_domain = domains_by_purchase[purchase].find { |domain| domain_blocks.key?(domain.downcase) }
      blocks[purchase.id] = domain_blocks[declining_domain.downcase] if declining_domain
    end
    blocks.compact
  end

  private
    attr_reader :failures

    # Keyed on the downcased value, because the lookup is case-insensitive but the hash is not: the
    # column collates utf8mb4_unicode_ci, so a row stored as `Example.COM` enforces against
    # `buyer@example.com` yet comes back under its own casing and would miss a case-sensitive key.
    #
    # Earliest by blocked_at, since that is the date a report is claiming the buyer has been stuck
    # since. Ties break on id so the pick is deterministic.
    def earliest_blocks_by_value(values, object_type: nil)
      scope = PlatformBlock.active.where(object_value: values)
      scope = scope.where(object_type:) if object_type
      scope.order(blocked_at: :asc, id: :asc)
           .each_with_object({}) { |block, blocks| blocks[block.object_value.downcase] ||= block }
    end

    # The same four domains Purchase::Blockable#blocked_by_email_domain_if_fraudulent_transaction?
    # reads. Reading fewer would drop a buyer blocked on, say, their account's domain — and dropping
    # them now means never reporting them.
    def blocked_domain_candidates(purchase)
      [:email_domain, :paypal_email_domain, :gifter_email_domain, :purchaser_email_domain].filter_map do |domain_method|
        purchase.send(domain_method)
      rescue Mail::Field::IncompleteParseError
        nil
      end.uniq
    end
end
