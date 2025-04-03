# frozen_string_literal: true

module Subscription::PingNotification
  def payload_for_ping_notification(resource_name: nil, additional_params: {})
    payload = {
      subscription_id: external_id,
      product_id: link.external_id,
      product_name: link.name,
      user_id: user.try(:external_id),
      user_email: email,
      purchase_ids: purchases.map(&:external_id),
      created_at: created_at.as_json,
      charge_occurrence_count:,
      recurrence: price.recurrence,
      free_trial_ends_at: free_trial_ends_at&.as_json,
      resource_name:
    }.merge(additional_params)

    payload[:custom_fields] = custom_fields.pluck(:name, :value).to_h if custom_fields.present?
    payload[:license_key] = license_key if license_key.present?

    if resource_name == ResourceSubscription::CANCELLED_RESOURCE_NAME
      payload[:cancelled] = true
      if cancelled_at.present?
        payload[:cancelled_at] = cancelled_at.as_json
        if cancelled_by_admin?
          payload[:cancelled_by_admin] = true
        elsif cancelled_by_buyer?
          payload[:cancelled_by_buyer] = true
        else
          payload[:cancelled_by_seller] = true
        end
      elsif failed_at.present?
        payload[:cancelled_at] = failed_at.as_json
        payload[:cancelled_due_to_payment_failures] = true
      end
    end

    if resource_name == ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME
      payload[:ended_at] = deactivated_at.as_json
      payload[:ended_reason] = termination_reason
    end

    payload
  end
end
