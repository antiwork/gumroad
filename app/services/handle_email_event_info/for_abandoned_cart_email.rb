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
      open_event = CreatorEmailOpenEvent.where(common_event_attributes(installment)).last
      if open_event.present?
        open_event.add_to_set(open_timestamps: Time.current)
        open_event.inc(open_count: 1)
      else
        CreatorEmailOpenEvent.create!(common_event_attributes(installment).merge(open_timestamps: [Time.current], open_count: 1))
      end

      update_installment_cache(installment, :unique_open_count)
    end

    def handle_click_event!(installment)
      return if email_event_info.click_url_as_mongo_key.blank?

      summary = CreatorEmailClickSummary.where(installment_id: installment.id).last
      if summary.present?
        email_click_event_args = common_event_attributes(installment)
        email_click_event_cache_key = Digest::MD5.hexdigest(email_click_event_args.inspect)

        email_click_event_present = Rails.cache.fetch("sendgrid_#{email_click_event_cache_key}") do
          # Return nil if `present?` returns false. That way, the query will be run again next time.
          CreatorEmailClickEvent.where(email_click_event_args).last.present? || nil
        end

        if email_click_event_present
          url_click_event_args = common_event_attributes(installment).merge(click_url: email_event_info.click_url_as_mongo_key)
          url_click_event_cache_key = Digest::MD5.hexdigest(url_click_event_args.inspect)

          url_click_event_present = Rails.cache.fetch("sendgrid_#{url_click_event_cache_key}") do
            # Return nil if `present?` returns false. That way, the query will be run again next time.
            CreatorEmailClickEvent.where(url_click_event_args).last.present? || nil
          end

          return if url_click_event_present
        else
          summary.inc(total_unique_clicks: 1)
        end
        summary.inc("urls.#{email_event_info.click_url_as_mongo_key}" => 1)
      else
        CreatorEmailClickSummary.create!(
          installment_id: installment.id,
          total_unique_clicks: 1,
          urls: { email_event_info.click_url_as_mongo_key => 1 }
        )
      end

      CreatorEmailClickEvent.create(
        common_event_attributes(installment).merge(
          click_url: email_event_info.click_url_as_mongo_key,
          click_timestamps: [Time.current],
          click_count: 1
        )
      )
      update_installment_cache(installment, :unique_click_count)

      # If a corresponding open event does not exist, create a new open event. This compensates for blocked image tracking pixels.
      unless CreatorEmailOpenEvent.where(common_event_attributes(installment)).exists?
        CreatorEmailOpenEvent.create!(common_event_attributes(installment).merge(open_timestamps: [Time.current], open_count: 1))
        update_installment_cache(installment, :unique_open_count)
      end
    end

    def update_installment_cache(installment, key)
      # Clear cache and precompute the result
      installment.invalidate_cache(key)
      installment.send(key)
    end

    def common_event_attributes(installment)
      {
        installment_id: installment.id,
        mailer_method: email_event_info.mailer_class_and_method,
        mailer_args: email_event_info.mailer_args,
      }
    end
end
