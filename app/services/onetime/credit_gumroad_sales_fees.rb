# frozen_string_literal: true

class Onetime::CreditGumroadSalesFees
  GUMROAD_DAY = Date.parse("07-04-2021")
  LAST_PURCHASE_TO_PROCESS = 36_793_417
  VIPUL_USER_ID = 2_241_816
  attr_accessor :purchases_to_credit_by_seller

  def initialize
    @purchases_to_credit_by_seller = Hash.new { |hash, key| hash[key] = [] }
  end

  def process
    identify_purchases_to_credit
    create_credits_and_notify_sellers
  end

  def identify_purchases_to_credit
    Purchase.where("created_at > ? AND id < ? AND fee_cents > 0", GUMROAD_DAY, LAST_PURCHASE_TO_PROCESS).successful
            .not_fully_refunded
            .not_chargedback_or_chargedback_reversed
            .find_each do |purchase|
      if purchase.created_at.in_time_zone("Eastern Time (US & Canada)").to_date == GUMROAD_DAY
        Rails.logger.info("Processing credit for purchase with id :: #{purchase.id}")

        purchases_to_credit_by_seller[purchase.seller.id] << purchase.id
      end
    end
  end

  def create_credits_and_notify_sellers
    vipul = User.find(VIPUL_USER_ID)

    Rails.logger.info("Sending notifications for all new_credits_by_seller :: #{purchases_to_credit_by_seller}")
    purchases_to_credit_by_seller.each do |user_id, purchases_to_credit|
      user = User.find user_id
      total_credits = user.sales.where(id: purchases_to_credit).map(&:total_fee_cents).sum

      Credit.create_for_credit!(user:,
                                amount_cents: total_credits,
                                crediting_user: vipul)

      ContactingCreatorMailer.gumroad_day_credit_notification(user_id,
                                                              total_credits).deliver_later(queue: "critical")
    end
  end
end
