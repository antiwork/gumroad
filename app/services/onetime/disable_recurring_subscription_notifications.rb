# frozen_string_literal: true

# One-time script to disable recurring subscription charge notifications
# (both email and push) for existing users.
#
# Usage:
#   Onetime::DisableRecurringSubscriptionNotifications.process
class Onetime::DisableRecurringSubscriptionNotifications
  def self.process
    updated_users = 0

    User.alive.find_in_batches(batch_size: 1000) do |batch|
      batch.each do |user|
        changed = false

        if user.enable_recurring_subscription_charge_email?
          user.enable_recurring_subscription_charge_email = false
          changed = true
        end

        if user.enable_recurring_subscription_charge_push_notification?
          user.enable_recurring_subscription_charge_push_notification = false
          changed = true
        end

        if changed
          # Skip validations/callbacks; we are only toggling flags.
          user.save!(validate: false)
          updated_users += 1
        end
      end
    end

    Rails.logger.info "Onetime::DisableRecurringSubscriptionNotifications: disabled flags for #{updated_users} users"
    true
  end
end
