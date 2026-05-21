# frozen_string_literal: true

class Radar::ValueListSyncService
  BLOCKED_EMAILS_LIST = "gumroad_blocked_emails"
  BLOCKED_CARDS_LIST = "gumroad_blocked_cards"
  SYNC_WINDOW = 25.hours
  STRIPE_FINGERPRINT_PATTERN = /\A[A-Za-z0-9]+\z/

  def sync_blocked_emails
    value_list = find_or_create_list(
      list_alias: BLOCKED_EMAILS_LIST,
      name: "Gumroad Blocked Emails",
      item_type: "email"
    )

    blocked_emails = PlatformBlock.email.active.where("blocked_at >= ?", SYNC_WINDOW.ago)
    blocked_emails.each do |blocked_object|
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
    value_list = find_or_create_list(
      list_alias: BLOCKED_CARDS_LIST,
      name: "Gumroad Blocked Cards",
      item_type: "card_fingerprint"
    )

    blocked_cards = PlatformBlock.charge_processor_fingerprint.active
      .where("blocked_at >= ?", SYNC_WINDOW.ago)
      .where("object_value REGEXP ?", STRIPE_FINGERPRINT_PATTERN.source)
    blocked_cards.each do |blocked_object|
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
    Stripe::Radar::ValueList.retrieve(list_alias)
  rescue Stripe::InvalidRequestError => e
    raise unless e.code == "resource_missing"
    Stripe::Radar::ValueList.create(
      alias: list_alias,
      name: name,
      item_type: item_type
    )
  end

  def add_item_to_list(value_list_id, value)
    Stripe::Radar::ValueListItem.create(
      value_list: value_list_id,
      value: value
    )
  rescue Stripe::InvalidRequestError => e
    raise unless e.code == "value_list_item_already_exists"
  end

  private
    def remove_item_from_list(value_list_id, value)
      items = Stripe::Radar::ValueListItem.list(value_list: value_list_id, value: value)
      items.data.each do |item|
        Stripe::Radar::ValueListItem.delete(item.id)
      end
    rescue Stripe::InvalidRequestError => e
      raise unless e.code == "resource_missing"
    end
end
