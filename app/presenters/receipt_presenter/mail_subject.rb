# frozen_string_literal: true

class ReceiptPresenter::MailSubject
  PRODUCT_NAME_CHARACTER_LIMIT = 27

  def self.build(chargeable)
    new(chargeable).build
  end

  def initialize(chargeable)
    @chargeable = chargeable
    @purchases = chargeable.unbundled_purchases
  end

  def build
    if purchases.one?
      build_for_one_purchase
    elsif purchases.count == 2
      build_for_two_purchases
    else
      build_for_more_than_two_purchases
    end
  end

  private
    attr_reader :chargeable, :purchases

    def build_for_one_purchase
      purchase = purchases.first
      subject = "You bought #{purchase.link_name}!"
      subject = "You got #{purchase.link_name}!" if purchase.price_cents == 0
      subject = "You rented #{purchase.link_name}!" if purchase.is_rental
      subject = "You've subscribed to #{purchase.link_name}!" if purchase.link.is_recurring_billing
      subject = "Recurring charge for #{purchase.link_name}." if purchase.link.is_recurring_billing && purchase.is_recurring_subscription_charge
      subject = "You've upgraded your membership for #{purchase.link_name}!" if purchase.link.is_recurring_billing && purchase.is_upgrade_purchase
      subject = "#{purchase.gifter_email} bought #{purchase.link_name} for you!" if purchase.is_gift_receiver_purchase
      subject = "#{purchase.gifter_full_name} (#{purchase.gifter_email}) bought #{purchase.link_name} for you!" if purchase.is_gift_receiver_purchase && purchase.gifter_full_name
      subject = "You bought #{purchase.giftee_name_or_email} #{purchase.link_name}!" if purchase.is_gift_sender_purchase
      subject = "#{purchase.link.name} is ready for download!" if purchase.is_commission_completion_purchase?
      subject
    end

    def build_for_two_purchases
      "You bought #{purchases.first.link_name.truncate(PRODUCT_NAME_CHARACTER_LIMIT)} and #{purchases.last.link_name.truncate(PRODUCT_NAME_CHARACTER_LIMIT)}"
    end

    def build_for_more_than_two_purchases
      "You bought #{purchases.first.link_name.truncate(PRODUCT_NAME_CHARACTER_LIMIT)} and #{purchases.count - 1} more products"
    end
end
