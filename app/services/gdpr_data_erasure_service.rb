# frozen_string_literal: true

class GdprDataErasureService
  ANONYMIZED_EMAIL_DOMAIN = "deleted.gumroad.com"
  ANONYMIZED_NAME = "[deleted]"
  ANONYMIZED_VALUE = "[redacted]"

  # Fields that must be retained for tax/legal compliance (Article 17(3)(b))
  # Transaction records, payout history, tax documents are kept.

  def initialize(user, performed_by:)
    @user = user
    @performed_by = performed_by
  end

  def perform!
    ActiveRecord::Base.transaction do
      deactivate_account!
      anonymize_user_pii!
      anonymize_buyer_purchases!
      remove_profile_assets!
      log_erasure!
    end

    { success: true, summary: erasure_summary }
  rescue => e
    Rails.logger.error("GDPR erasure failed for user #{@user.id}: #{e.message}")
    { success: false, error: e.message }
  end

  private

    def deactivate_account!
      return if @user.deleted?

      @user.update!(
        deleted_at: Time.current,
        username: nil,
        credit_card_id: nil,
        payouts_paused_internally: true,
      )

      @user.links.each(&:delete!)
      @user.installments.alive.each(&:mark_deleted!)
      @user.user_compliance_infos.alive.each(&:mark_deleted!)
      @user.bank_accounts.alive.each(&:mark_deleted!)
      @user.cancel_active_subscriptions!
      @user.invalidate_active_sessions!

      if @user.custom_domain&.persisted? && !@user.custom_domain.deleted?
        @user.custom_domain.mark_deleted!
      end
    end

    def anonymize_user_pii!
      anonymized_email = "deleted-#{@user.id}@#{ANONYMIZED_EMAIL_DOMAIN}"

      @user.update_columns(
        email: anonymized_email,
        name: ANONYMIZED_NAME,
        encrypted_password: "",
        reset_password_token: nil,
        current_sign_in_ip: nil,
        last_sign_in_ip: nil,
        account_created_ip: nil,
        payment_address: nil,
        unconfirmed_email: nil,
        bio: nil,
        twitter_handle: nil,
        twitter_user_id: nil,
        facebook_uid: nil,
        facebook_access_token: nil,
        twitter_oauth_token: nil,
        twitter_oauth_secret: nil,
        profile_picture_url: nil,
        street_address: nil,
        city: nil,
        state: nil,
        zip_code: nil,
        country: nil,
        kindle_email: nil,
        support_email: nil,
        google_analytics_id: nil,
        google_analytics_domains: nil,
        facebook_pixel_id: nil,
        notification_endpoint: nil,
        otp_secret_key: nil,
      )
    end

    def anonymize_buyer_purchases!
      # Anonymize PII on purchases made as a buyer
      # Keep transaction amounts and dates for tax/legal compliance
      Purchase.where(purchaser_id: @user.id).update_all(
        full_name: ANONYMIZED_NAME,
        street_address: nil,
        city: nil,
        state: nil,
        zip_code: nil,
        country: nil,
      )

      # Anonymize purchases by email (guest purchases)
      Purchase.where(email: @user.email_was || @user.email).where(purchaser_id: nil).update_all(
        full_name: ANONYMIZED_NAME,
        street_address: nil,
        city: nil,
        state: nil,
        zip_code: nil,
        country: nil,
      )
    end

    def remove_profile_assets!
      @user.avatar&.purge if @user.respond_to?(:avatar) && @user.avatar&.attached?
    rescue => e
      Rails.logger.warn("GDPR: Failed to purge avatar for user #{@user.id}: #{e.message}")
    end

    def log_erasure!
      @user.comments.create!(
        author_id: @performed_by.id,
        author_name: @performed_by.name || @performed_by.email,
        comment_type: "gdpr_erasure",
        content: "GDPR data erasure performed. User PII anonymized, account deactivated. " \
                 "Transaction records retained per Article 17(3)(b). " \
                 "External cleanup required: Helper/Supabase, Gmail, Stripe."
      )
    end

    def erasure_summary
      {
        user_id: @user.id,
        email_anonymized: true,
        profile_anonymized: true,
        purchases_anonymized: true,
        account_deactivated: true,
        products_deleted: @user.links.count,
        external_cleanup_needed: [
          "Helper/Supabase (customer conversations)",
          "Gmail (correspondence)",
          "Stripe (customer data)"
        ]
      }
    end
end
