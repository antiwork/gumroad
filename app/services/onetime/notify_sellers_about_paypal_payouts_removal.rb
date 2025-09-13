# frozen_string_literal: true

class Onetime::NotifySellersAboutPaypalPayoutsRemoval
  def self.process
    User.alive.not_suspended
        .where("users.id > ?", $redis.get("notified_paypal_removal_till_user_id").to_i)
        .joins(:user_compliance_infos)
        .where("user_compliance_info.deleted_at IS NULL AND user_compliance_info.country IN (?)", User::Compliance.const_get(:SUPPORTED_COUNTRIES).map(&:common_name) - ["India", "United Arab Emirates"])
        .joins(:payments)
        .where("payments.processor = 'paypal' AND payments.state = 'completed' and payments.created_at > ?", Date.new(2025, 1, 1))
        .order("users.id")
        .select("users.id")
        .distinct
        .each do |user|
      ReplicaLagWatcher.watch
      ContactingCreatorMailer.paypal_suspension_notification(user.id).deliver_later
      $redis.set("notified_paypal_removal_till_user_id", user.id)
    end
  end
end
