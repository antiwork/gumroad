# frozen_string_literal: true

class Radar::ValueListSyncService
  BLOCKED_EMAILS_LIST = "gumroad_blocked_emails"
  BLOCKED_CARDS_LIST = "gumroad_blocked_cards"
  SYNC_WINDOW = 25.hours
  STRIPE_FINGERPRINT_PATTERN = /\A[A-Za-z0-9]+\z/

  LIST_FOR_TYPE = {
    PlatformBlock::TYPES[:email] => { list_alias: BLOCKED_EMAILS_LIST, name: "Gumroad Blocked Emails", item_type: "email" },
    PlatformBlock::TYPES[:charge_processor_fingerprint] => { list_alias: BLOCKED_CARDS_LIST, name: "Gumroad Blocked Cards", item_type: "card_fingerprint" },
  }.freeze

  # The other PlatformBlock types (ip_address, browser_guid, email_domain, product) are enforced
  # in-app, so there is no Radar item to remove for them.
  def self.syncs?(object_type)
    LIST_FOR_TYPE.key?(object_type)
  end

  # Radar value lists are durable account-wide state, and every non-production environment
  # (dev, CI, cassette recording, branch apps) shares one Stripe test account. A block-buyer
  # flow leaking through here once blocked the 4242 test card's fingerprint for the whole
  # account and every checkout spec declined until the item was deleted by hand.
  def self.enabled?
    Rails.env.production? || GlobalConfig.get("ENABLE_RADAR_VALUE_LIST_SYNC").present?
  end

  # A stale removal keeps rejecting a legitimate buyer; adds can wait for the daily sync.
  def remove_block(platform_block)
    return false unless self.class.enabled?

    list_config = LIST_FOR_TYPE[platform_block.object_type]
    return false if list_config.nil?
    return false if platform_block.reload.blocked_at.present?

    value = platform_block.object_value
    return false if platform_block.charge_processor_fingerprint? && !value.match?(STRIPE_FINGERPRINT_PATTERN)

    value_list_id = find_or_create_list(**list_config).id
    remove_item_from_list(value_list_id, value)

    # A block re-added between the check above and the delete would otherwise lose Radar
    # enforcement until tomorrow's sync, so put the item back instead of leaving the gap.
    if reblocked?(platform_block.object_type, value)
      add_item_to_list(value_list_id, value)
      return false
    end

    true
  end

  # The counterpart to remove_block, enqueued off add!. Neither side can be made atomic with the
  # Stripe call, so the two are made to converge instead: whichever order an add and a removal
  # interleave in, the loser's own job re-reads the row and re-asserts Radar within seconds.
  # Without this, only the removal recovered and a block added mid-removal stayed unenforced
  # until the daily sync.
  def add_block(platform_block)
    return false unless self.class.enabled?

    list_config = LIST_FOR_TYPE[platform_block.object_type]
    return false if list_config.nil?
    return false if platform_block.reload.blocked_at.nil?

    value = platform_block.object_value
    return false if platform_block.charge_processor_fingerprint? && !value.match?(STRIPE_FINGERPRINT_PATTERN)

    value_list_id = find_or_create_list(**list_config).id
    add_item_to_list(value_list_id, value)

    # Cleared while the add was in flight: leaving the item behind keeps rejecting a buyer whose
    # block is gone, which is the failure this whole change exists to stop.
    if !reblocked?(platform_block.object_type, value)
      remove_item_from_list(value_list_id, value)
      return false
    end

    true
  end

  def sync_blocked_emails
    return unless self.class.enabled?

    value_list = find_or_create_list(**LIST_FOR_TYPE[PlatformBlock::TYPES[:email]])

    blocked_emails = PlatformBlock.email.active.where("blocked_at >= ?", SYNC_WINDOW.ago)
    blocked_emails.each do |blocked_object|
      next if unblocked_since_select?(blocked_object)
      add_item_to_list(value_list.id, blocked_object.object_value)
    end

    recently_unblocked_emails = PlatformBlock.email.where(blocked_at: nil).where("updated_at >= ?", SYNC_WINDOW.ago)
    recently_unblocked_emails.each do |blocked_object|
      remove_item_from_list(value_list.id, blocked_object.object_value)
    end

    expired_emails = PlatformBlock.email.where.not(blocked_at: nil).where(expires_at: SYNC_WINDOW.ago..Time.current)
    expired_emails.each do |blocked_object|
      remove_item_from_list(value_list.id, blocked_object.object_value)
    end
  end

  def sync_blocked_cards
    return unless self.class.enabled?

    value_list = find_or_create_list(**LIST_FOR_TYPE[PlatformBlock::TYPES[:charge_processor_fingerprint]])

    blocked_cards = PlatformBlock.charge_processor_fingerprint.active
      .where("blocked_at >= ?", SYNC_WINDOW.ago)
      .where("object_value REGEXP ?", STRIPE_FINGERPRINT_PATTERN.source)
    blocked_cards.each do |blocked_object|
      next if unblocked_since_select?(blocked_object)
      add_item_to_list(value_list.id, blocked_object.object_value)
    end

    recently_unblocked_cards = PlatformBlock.charge_processor_fingerprint
      .where(blocked_at: nil)
      .where("updated_at >= ?", SYNC_WINDOW.ago)
      .where("object_value REGEXP ?", STRIPE_FINGERPRINT_PATTERN.source)
    recently_unblocked_cards.each do |blocked_object|
      remove_item_from_list(value_list.id, blocked_object.object_value)
    end

    expired_cards = PlatformBlock.charge_processor_fingerprint
      .where.not(blocked_at: nil)
      .where(expires_at: SYNC_WINDOW.ago..Time.current)
      .where("object_value REGEXP ?", STRIPE_FINGERPRINT_PATTERN.source)
    expired_cards.each do |blocked_object|
      remove_item_from_list(value_list.id, blocked_object.object_value)
    end
  end

  def find_or_create_list(list_alias:, name:, item_type:)
    existing = Stripe::Radar::ValueList.list(alias: list_alias, limit: 1).data.first
    return existing if existing

    begin
      Stripe::Radar::ValueList.create(
        alias: list_alias,
        name: name,
        item_type: item_type
      )
    rescue Stripe::InvalidRequestError => e
      raise unless e.message.to_s.include?("already exists")
      Stripe::Radar::ValueList.list(alias: list_alias, limit: 1).data.first ||
        raise("Radar value list '#{list_alias}' could not be found after race recovery")
    end
  end

  def add_item_to_list(value_list_id, value)
    Stripe::Radar::ValueListItem.create(
      value_list: value_list_id,
      value: value
    )
  rescue Stripe::InvalidRequestError => e
    raise unless e.code == "value_list_item_already_exists" || e.message.to_s.include?("already exists")
  end

  private
    def reblocked?(object_type, object_value)
      PlatformBlock.active.exists?(object_type:, object_value:)
    end

    # The add loop makes one sequential Stripe call per row, so a row cleared after the SELECT
    # would otherwise be re-added — restoring the very block the removal job just lifted.
    def unblocked_since_select?(platform_block)
      platform_block.reload.blocked_at.nil?
    rescue ActiveRecord::RecordNotFound
      true
    end

    def remove_item_from_list(value_list_id, value)
      items = Stripe::Radar::ValueListItem.list(value_list: value_list_id, value: value)
      items.data.each do |item|
        Stripe::Radar::ValueListItem.delete(item.id)
      end
    rescue Stripe::InvalidRequestError => e
      raise unless e.code == "resource_missing"
    end
end
