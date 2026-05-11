# frozen_string_literal: true

class Radar::ValueListSyncService
  BLOCKED_EMAILS_LIST = "gumroad_blocked_emails"
  BLOCKED_CARDS_LIST = "gumroad_blocked_cards"

  def sync_blocked_emails
    value_list = find_or_create_list(
      list_alias: BLOCKED_EMAILS_LIST,
      name: "Gumroad Blocked Emails",
      item_type: "email"
    )

    blocked_emails = BlockedObject.email.active.where(:created_at.gte => 1.day.ago)
    blocked_emails.each do |blocked_object|
      add_item_to_list(value_list.id, blocked_object.object_value)
    end
  end

  def sync_blocked_cards
    value_list = find_or_create_list(
      list_alias: BLOCKED_CARDS_LIST,
      name: "Gumroad Blocked Cards",
      item_type: "card_fingerprint"
    )

    blocked_cards = BlockedObject.charge_processor_fingerprint.active.where(:created_at.gte => 1.day.ago)
    blocked_cards.each do |blocked_object|
      add_item_to_list(value_list.id, blocked_object.object_value)
    end
  end

  private

  def find_or_create_list(list_alias:, name:, item_type:)
    Stripe::Radar::ValueList.retrieve(list_alias)
  rescue Stripe::InvalidRequestError
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
    raise unless e.message.include?("already exists")
  end
end
