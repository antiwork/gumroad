# frozen_string_literal: true

class HandleEmailEventInfo::ForAbandonedCartEmail
  attr_reader :email_event_info

  def self.perform(email_event_info)
    new(email_event_info).perform
  end

  def initialize(email_event_info)
    @email_event_info = email_event_info
  end

  def perform
    email_event_info.workflow_ids.each do |workflow_id|
      workflow = Workflow.find(workflow_id)

      installment = workflow.alive_installments.sole
      case email_event_info.type
      when EmailEventInfo::EVENT_DELIVERED
        handle_delivered_event!(installment)
      when EmailEventInfo::EVENT_OPENED
        handle_open_event!(installment)
      when EmailEventInfo::EVENT_CLICKED
        handle_click_event!(installment)
      end
    end
  end

  private
    def handle_delivered_event!(installment)
      installment.increment_total_delivered(by: 1)
    end

    def handle_open_event!(installment)
      EmailEngagementDynamoStore.record_open(**common_event_attributes(installment))
      update_installment_cache(installment, :unique_open_count)
    end

    def handle_click_event!(installment)
      return if email_event_info.click_url_as_mongo_key.blank?

      EmailEngagementDynamoStore.record_click(**common_event_attributes(installment), click_url: email_event_info.click_url_as_mongo_key)
      update_installment_cache(installment, :unique_click_count)
      update_installment_cache(installment, :unique_open_count)
    end

    def update_installment_cache(installment, key)
      installment.invalidate_cache(key)
      installment.invalidate_legacy_engagement_cache(key)
    end

    def common_event_attributes(installment)
      {
        installment_id: installment.id,
        mailer_method: email_event_info.mailer_class_and_method,
        mailer_args: email_event_info.mailer_args,
      }
    end
end
