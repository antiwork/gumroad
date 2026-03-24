# frozen_string_literal: true

class Onetime::IncreaseMinimumPayoutThreshold
  def self.process
    User.where("json_data LIKE '%payout_threshold_cents%'").find_each do |user|
      ReplicaLagWatcher.watch
      next if user.payout_threshold_cents.nil? || user.payout_threshold_cents >= Payouts::MIN_AMOUNT_CENTS

      user.update!(payout_threshold_cents: Payouts::MIN_AMOUNT_CENTS)
    end
  end
end
