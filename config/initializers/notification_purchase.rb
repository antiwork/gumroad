# frozen_string_literal: true

Rails.application.config.after_initialize do
  ActiveSupport::Notifications.subscribe(ChargeProcessor::NOTIFICATION_CHARGE_EVENT) do |_, _, _, _, payload|
    Purchase.handle_charge_event(payload[:charge_event])
  end
end
