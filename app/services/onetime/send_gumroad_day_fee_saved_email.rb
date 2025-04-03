# frozen_string_literal: true

class Onetime::SendGumroadDayFeeSavedEmail
  def self.process
    start_time = DateTime.new(2024, 4, 4, 0, 0, 0, "+14:00")
    end_time = DateTime.new(2024, 4, 5, 0, 0, 0, "-13:00")

    Purchase.joins(:seller)
            .non_free
            .not_recurring_charge
            .where(purchase_state: Purchase::NON_GIFT_SUCCESS_STATES)
            .where("purchases.created_at >= ? AND purchases.created_at < ?", start_time, end_time)
            .where("users.json_data LIKE '%gumroad_day_timezone%'")
            .where("users.id > ?", $redis.get("gumroad_day_fee_saved_email_last_user_id").to_i)
            .select("users.id")
            .distinct
            .order("users.id")
            .each do |user|
      ReplicaLagWatcher.watch
      next unless User.find(user.id).gumroad_day_saved_fee_cents > 0

      CreatorMailer.gumroad_day_fee_saved(seller_id: user.id).deliver_later(queue: "mongo")

      $redis.set("gumroad_day_fee_saved_email_last_user_id", user.id)
      puts "Enqueued gumroad_day_fee_saved email for #{user.id}"
    end
  end
end
