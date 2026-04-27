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
    @products_deleted = 0
  end

  def perform!
    original_email = @user.email
    credit_card_ids = credit_card_ids_for_erasure

    ActiveRecord::Base.transaction do
      @products_deleted = deactivate_account!
      anonymized_email = anonymize_user_pii!
      delete_device_records!
      anonymize_carts!(anonymized_email)
      anonymize_credit_cards!(credit_card_ids)
      anonymize_buyer_purchases!(anonymized_email:, original_email:)
      log_erasure!
    end

    remove_profile_assets!

    { success: true, summary: erasure_summary }
  rescue => e
    Rails.logger.error("GDPR erasure failed for user #{@user.id}: #{e.message}")
    { success: false, error: e.message }
  end

  private
    def deactivate_account!
      return 0 if @user.deleted?

      products_deleted = @user.links.alive.count

      # Skip balance validation for GDPR erasure. We are legally obligated
      # to erase regardless of outstanding balance (Article 17).
      @user.update!(
        deleted_at: Time.current,
        username: nil,
        credit_card_id: nil,
        payouts_paused_internally: true,
      )

      @user.links.alive.each(&:delete!)
      @user.installments.alive.each(&:mark_deleted!)
      @user.user_compliance_infos.alive.each(&:mark_deleted!)
      @user.bank_accounts.alive.each(&:mark_deleted!)
      @user.send(:cancel_active_subscriptions!)
      @user.invalidate_active_sessions!

      if @user.custom_domain&.persisted? && !@user.custom_domain.deleted?
        @user.custom_domain.mark_deleted!
      end

      products_deleted
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

      anonymized_email
    end

    def anonymize_carts!(anonymized_email)
      @user.carts.update_all(
        email: anonymized_email,
        ip_address: nil,
        browser_guid: nil,
      )
    end

    def delete_device_records!
      @user.devices.destroy_all
    end

    def anonymize_credit_cards!(credit_card_ids)
      return if credit_card_ids.empty?

      CreditCard.where(id: credit_card_ids).update_all(
        card_type: ANONYMIZED_VALUE,
        expiry_month: nil,
        expiry_year: nil,
        stripe_customer_id: nil,
        visual: ANONYMIZED_VALUE,
        stripe_fingerprint: nil,
        card_country: nil,
        stripe_card_id: nil,
        card_bin: nil,
        card_data_handling_mode: nil,
        braintree_customer_id: nil,
        funding_type: nil,
        paypal_billing_agreement_id: nil,
        processor_payment_method_id: nil,
        json_data: nil,
        updated_at: Time.current,
      )
    end

    def anonymize_buyer_purchases!(anonymized_email:, original_email:)
      # Anonymize PII on purchases made as a buyer
      # Keep transaction amounts and dates for tax/legal compliance
      Purchase.where(purchaser_id: @user.id).update_all(
        email: anonymized_email,
        full_name: ANONYMIZED_NAME,
        street_address: nil,
        city: nil,
        state: nil,
        zip_code: nil,
        country: nil,
        ip_address: nil,
        browser_guid: nil,
      )

      # Anonymize purchases by email (guest purchases)
      return if original_email.blank?

      Purchase.where(email: original_email, purchaser_id: nil).update_all(
        email: anonymized_email,
        full_name: ANONYMIZED_NAME,
        street_address: nil,
        city: nil,
        state: nil,
        zip_code: nil,
        country: nil,
        ip_address: nil,
        browser_guid: nil,
      )
    end

    def remove_profile_assets!
      @user.avatar&.purge if @user.respond_to?(:avatar) && @user.avatar&.attached?
    rescue => e
      Rails.logger.warn("GDPR: Failed to purge avatar for user #{@user.id}: #{e.message}")
    end

    def credit_card_ids_for_erasure
      [
        @user.credit_card_id,
        @user.purchases.where.not(credit_card_id: nil).distinct.pluck(:credit_card_id),
        @user.subscriptions.where.not(credit_card_id: nil).distinct.pluck(:credit_card_id),
        @user.bank_accounts.where.not(credit_card_id: nil).distinct.pluck(:credit_card_id),
      ].flatten.compact.uniq
    end

    def log_erasure!
      @user.comments.create!(
        author_id: @performed_by.id,
        author_name: @performed_by.name || @performed_by.email,
        comment_type: Comment::COMMENT_TYPE_NOTE,
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
        products_deleted: @products_deleted,
        external_cleanup_needed: [
          "Helper/Supabase (customer conversations)",
          "Gmail (correspondence)",
          "Stripe (customer data)"
        ]
      }
    end
end
