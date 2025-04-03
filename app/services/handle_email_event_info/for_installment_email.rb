# frozen_string_literal: true

class HandleEmailEventInfo::ForInstallmentEmail
  attr_reader :email_event_info

  def self.perform(email_event_info)
    new(email_event_info).perform
  end

  def initialize(email_event_info)
    @email_event_info = email_event_info
  end

  def perform
    case email_event_info.type
    when EmailEventInfo::EVENT_BOUNCED
      handle_bounce_event!
    when EmailEventInfo::EVENT_DELIVERED
      handle_delivered_event!
    when EmailEventInfo::EVENT_OPENED
      handle_open_event!
    when EmailEventInfo::EVENT_CLICKED
      handle_click_event!
    when EmailEventInfo::EVENT_COMPLAINED
      unless email_event_info.email_provider == MailerInfo::EMAIL_PROVIDER_RESEND
        handle_spamreport_event!
      end
    end
  end

  private
    def handle_bounce_event!
      email_info = pull_creator_contacting_customers_email_info(email_event_info)
      if email_info.present?
        email_info.mark_bounced!
      else
        # Unsubscribe the follower
        seller_id = Installment.find(email_event_info.installment_id).seller_id
        Follower.unsubscribe(seller_id, email_event_info.email)
      end
    end

    def handle_delivered_event!
      email_info = pull_creator_contacting_customers_email_info(email_event_info)
      email_info.mark_delivered!(email_event_info.created_at) if email_info.present?
    end

    def handle_open_event!
      open_event = CreatorEmailOpenEvent.where(
        mailer_method: email_event_info.mailer_class_and_method,
        mailer_args: email_event_info.mailer_args,
        installment_id: email_event_info.installment_id
      ).last
      if open_event.present?
        open_event.add_to_set(open_timestamps: Time.current)
        open_event.inc(open_count: 1)
      else
        CreatorEmailOpenEvent.create!(
          mailer_method: email_event_info.mailer_class_and_method,
          mailer_args: email_event_info.mailer_args,
          installment_id: email_event_info.installment_id,
          open_timestamps: [Time.current],
          open_count: 1
        )
      end

      email_info = pull_creator_contacting_customers_email_info(email_event_info)
      email_info.mark_opened!(email_event_info.created_at) if email_info.present?

      update_installment_cache(email_event_info.installment_id, :unique_open_count)
    end

    def handle_click_event!
      return if email_event_info.click_url_as_mongo_key.blank?

      summary = CreatorEmailClickSummary.where(installment_id: email_event_info.installment_id).last
      if summary.present?
        email_click_event_args = {
          installment_id: email_event_info.installment_id,
          mailer_method: email_event_info.mailer_class_and_method,
          mailer_args: email_event_info.mailer_args,
        }
        email_click_event_cache_key = Digest::MD5.hexdigest(email_click_event_args.inspect)

        email_click_event_present = Rails.cache.fetch("#{email_event_info.email_provider}_#{email_click_event_cache_key}") do
          # Return nil if `present?` returns false. That way, the query will be run again next time.
          CreatorEmailClickEvent.where(email_click_event_args).last.present? || nil
        end

        if email_click_event_present
          url_click_event_args = {
            installment_id: email_event_info.installment_id,
            mailer_method: email_event_info.mailer_class_and_method,
            mailer_args: email_event_info.mailer_args,
            click_url: email_event_info.click_url_as_mongo_key
          }
          url_click_event_cache_key = Digest::MD5.hexdigest(url_click_event_args.inspect)

          url_click_event_present = Rails.cache.fetch("#{email_event_info.email_provider}_#{url_click_event_cache_key}") do
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
          installment_id: email_event_info.installment_id,
          total_unique_clicks: 1,
          urls: { email_event_info.click_url_as_mongo_key => 1 }
        )
      end

      CreatorEmailClickEvent.create(
        installment_id: email_event_info.installment_id,
        mailer_args: email_event_info.mailer_args,
        mailer_method: email_event_info.mailer_class_and_method,
        click_url: email_event_info.click_url_as_mongo_key,
        click_timestamps: [Time.current],
        click_count: 1
      )
      update_installment_cache(email_event_info.installment_id, :unique_click_count)

      # If a corresponding open event does not exist, create a new open event. This compensates for blocked image tracking pixels.
      unless creator_email_open_event_exists?(email_event_info)
        CreatorEmailOpenEvent.create!(
          installment_id: email_event_info.installment_id,
          mailer_method: email_event_info.mailer_class_and_method,
          mailer_args: email_event_info.mailer_args,
          open_timestamps: [Time.current],
          open_count: 1
        )

        update_installment_cache(email_event_info.installment_id, :unique_open_count)
      end
    end

    def handle_spamreport_event!
      purchase = Purchase.find_by(id: email_event_info.purchase_id)

      if purchase.present?
        purchase.unsubscribe_buyer
      else
        # Unsubscribe the follower
        seller_id = Installment.find(email_event_info.installment_id).seller_id
        Follower.unsubscribe(seller_id, email_event_info.email)
      end
    end

    def pull_creator_contacting_customers_email_info(email_event_info)
      purchase_id = email_event_info.purchase_id
      installment_id = email_event_info.installment_id
      email_name = nil
      if email_event_info.mailer_class_and_method.end_with?(EmailEventInfo::PURCHASE_INSTALLMENT_MAILER_METHOD)
        email_name = EmailEventInfo::PURCHASE_INSTALLMENT_MAILER_METHOD
        email_info = CreatorContactingCustomersEmailInfo.where(purchase_id:, installment_id:).last
      elsif email_event_info.mailer_class_and_method.end_with?(EmailEventInfo::SUBSCRIPTION_INSTALLMENT_MAILER_METHOD)
        email_name = EmailEventInfo::SUBSCRIPTION_INSTALLMENT_MAILER_METHOD
        purchase_id = Subscription.find(email_event_info.purchase_id).original_purchase.id
        email_info = CreatorContactingCustomersEmailInfo.where(purchase_id:, installment_id:).last
      else
        return nil
      end

      # We create these records when sending emails so we shouldn't really need to create them again here.
      # However, this code needs to stay so as to support events which are triggered on emails which were sent before
      # the code to create these records was in place. From our investigation, we saw that we still receive events
      # for ancient purchases.
      email_info || CreatorContactingCustomersEmailInfo.new(purchase_id:, installment_id:, email_name:)
    end

    def update_installment_cache(installment_id, key)
      installment = Installment.find(installment_id)

      # Clear cache and precompute the result
      installment.invalidate_cache(key)
      installment.send(key)
    end

    def creator_email_open_event_exists?(email_event_info)
      CreatorEmailOpenEvent.where(
        installment_id: email_event_info.installment_id,
        mailer_method: email_event_info.mailer_class_and_method,
        mailer_args: email_event_info.mailer_args,
      ).exists?
    end
end
