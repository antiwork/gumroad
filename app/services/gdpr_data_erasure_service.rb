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
    # Read before the transaction so the Stripe deletion below has the account id and the Person
    # ids to hand. The values would survive the transaction unchanged, but resolving them up front
    # keeps the deletion independent of what erasure does to the account in between.
    guardian_stripe_persons = guardian_stripe_persons_for_erasure

    ActiveRecord::Base.transaction do
      @products_deleted = deactivate_account!
      anonymized_email = anonymize_user_pii!
      anonymize_compliance_info!
      delete_device_records!
      anonymize_carts!(anonymized_email)
      anonymize_credit_cards!(credit_card_ids)
      anonymize_buyer_purchases!(anonymized_email:, original_email:)
      log_erasure!
    end

    remove_profile_assets!
    delete_guardian_stripe_persons!(guardian_stripe_persons)

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

    def anonymize_compliance_info!
      # Compliance (KYC) records hold the person's legal name, date of birth, street
      # address, and phone number. deactivate_account! only soft-deletes them, which hides
      # the rows from the app but leaves that data in the table, so erasure must also null
      # the columns. This intentionally covers every row for the user, not just alive ones:
      # UserComplianceInfo is Immutable, meaning each edit creates a new row and soft-deletes
      # the previous one, and those older rows hold the same PII. update_all writes SQL
      # directly, which also bypasses the Immutable guard — appropriate here because this is
      # a legally mandated destruction (Article 17), not a normal edit.
      #
      # json_data is nulled because it stores PII too: phone numbers, nationality, and the
      # kana/kanji name and address variants used for Japanese accounts. Country and the
      # tax ids (encrypted at rest) are retained with the transaction and tax records per
      # Article 17(3)(b), as are the business-entity columns.
      @user.user_compliance_infos.update_all(
        full_name: nil,
        first_name: nil,
        last_name: nil,
        birthday: nil,
        street_address: nil,
        city: nil,
        state: nil,
        zip_code: nil,
        telephone_number: nil,
        json_data: nil,
        updated_at: Time.current,
      )

      # A seller who was under 18 has an adult legal guardian attached, whose own name, date of
      # birth, address and phone number are held on a separate row that the update above does not
      # reach. That adult is a third party to this request but their details only exist because of
      # this account, so they go too. The row itself is kept, and so is the reference to it, because
      # the compliance revisions above are an audit trail and clearing the link would silently
      # rewrite it. Read across every revision, not just alive ones, for the same reason.
      #
      # Scoped by owner rather than by the revisions that reference it: a guardian belongs to one
      # seller, so this also reaches a guardian whose details were entered before any revision
      # pointed at them, and can never reach another seller's.
      @user.guardians.each(&:anonymize!)
    end

    # The guardian's details are also held by Stripe, as the legal-guardian Person on the seller's
    # payout account. Anonymizing our row does not reach that copy, so erasure has to delete it
    # there too or the adult's name, date of birth and address survive the request at our processor.
    #
    # Outside the transaction on purpose: this is a network call, and holding a write transaction
    # open across it would keep locks on the rows above for the duration of Stripe's response.
    # Per-guardian rescue for the same reason the file purge has one — one failed delete must not
    # skip the rest. A failure here leaves a Person at Stripe that our row no longer describes, so
    # it is reported rather than logged quietly.
    def delete_guardian_stripe_persons!(guardian_stripe_persons)
      guardian_stripe_persons.each do |stripe_person_id, stripe_account_id|
        StripeGuardianManager.delete_person_by_id(stripe_person_id, stripe_account_id)
      rescue => e
        Rails.logger.error("GDPR: Failed to delete Stripe guardian person for user #{@user.id}: #{e.message}")
        ErrorNotifier.notify(e)
      end
    end

    # Pairs each guardian Person with the Stripe account it lives on, resolved while the account is
    # still active. Includes Persons found by relationship scan: a sync that created one but failed
    # to record its id leaves no local pointer, and that PII must still go.
    def guardian_stripe_persons_for_erasure
      stripe_account_id = @user.stripe_account&.charge_processor_merchant_id
      return [] if stripe_account_id.blank?

      StripeGuardianManager
        .stripe_person_ids_for_erasure(@user.guardians.to_a, stripe_account_id)
        .map { |stripe_person_id| [stripe_person_id, stripe_account_id] }
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

      # The user's public media library (files uploaded via Api::V2::MediaController) lives on
      # Gumroad's public CDN. Erasure has to take those files down too — soft-deleting the records
      # would leave the public URLs serving the content. Purges each blob unless another record
      # still references it.
      # Rescue per file rather than letting one failure bubble up to the method-level rescue
      # below: find_each stops at the first raised error, which would silently leave every
      # remaining file publicly accessible after the erasure completes.
      PublicFile.alive.where(seller: @user, resource: @user).find_each do |file|
        file.mark_deleted_and_purge_file!
      rescue => e
        Rails.logger.warn("GDPR: Failed to purge media file #{file.id} for user #{@user.id}: #{e.message}")
      end
    rescue => e
      Rails.logger.warn("GDPR: Failed to purge profile assets for user #{@user.id}: #{e.message}")
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
        compliance_info_anonymized: true,
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
