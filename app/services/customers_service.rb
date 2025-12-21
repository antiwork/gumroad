# frozen_string_literal: true

class CustomersService
  class CustomerDNDEnabledError < StandardError; end
  class PostNotSentError < StandardError; end
  class SellerNotEligibleError < StandardError; end

  POST_EMAIL_CACHE_EXPIRATION_TIME = 8.hours

  class << self
    def find_missed_posts_for(purchase:, workflow_id: nil)
      Installment.missed_for_purchase(purchase, workflow_id:)
    end

    def find_sent_posts_for(purchase)
      latest_email_ids = CreatorContactingCustomersEmailInfo
      .where(purchase:, installment_id: Installment.seller_or_product_or_variant_type_for_purchase(purchase).alive.published.pluck(:id))
      .group(:installment_id)
      .maximum(:id)
      .values

      CreatorContactingCustomersEmailInfo
        .where(id: latest_email_ids)
        .order(sent_at: :desc)
    end

    def find_workflow_options_for(purchase)
      purchase.seller.workflows.alive.published
      .joins(:installments)
      .merge(
        Installment.seller_or_product_or_variant_type_for_purchase(purchase).alive.published
      )
      .distinct
      .order(:name)
      .filter { |workflow| workflow.applies_to_purchase?(purchase) }
    end

    def send_post!(post:, purchase:)
      validate_email_sending_eligibility_for!(purchase.seller)
      validate_customer_can_be_contacted_via_email_for!(purchase)

      # Limit the number of emails sent per post to avoid abuse.
      Rails.cache.fetch("post_email:#{post.id}:#{purchase.id}", expires_in: POST_EMAIL_CACHE_EXPIRATION_TIME) do
        CreatorContactingCustomersEmailInfo.destroy_by(purchase:, installment: post)

        PostEmailApi.process(
          post:,
          recipients: [{
            email: purchase.email,
            purchase:,
            url_redirect: purchase.url_redirect,
            subscription: purchase.subscription,
          }.compact_blank]
        )
        true
      end
    end

    def send_missed_posts_for!(purchase:, workflow_id: nil)
      validate_email_sending_eligibility_for!(purchase.seller)
      validate_customer_can_be_contacted_via_email_for!(purchase)

      SendMissedPostsJob.perform_async(purchase.external_id, workflow_id)
    end

    def deliver_missed_posts_for!(purchase:, workflow_id: nil)
      find_missed_posts_for(purchase:, workflow_id:).find_each do |post|
        send_post!(post:, purchase:)
      rescue CustomerDNDEnabledError, SellerNotEligibleError => e
        raise e
      rescue StandardError => e
        raise PostNotSentError, "Missed post #{post.id} could not be sent. Aborting batch sending for the remaining posts. Original message: #{e.message}", e.backtrace
      end
    end

    private
      def validate_email_sending_eligibility_for!(seller)
        raise SellerNotEligibleError, "You are not eligible to resend this email." unless seller&.eligible_to_send_emails?
      end

      def validate_customer_can_be_contacted_via_email_for!(purchase)
        raise CustomerDNDEnabledError, "Purchase #{purchase.id} has opted out of receiving emails" unless purchase.can_contact?
      end
  end
end
