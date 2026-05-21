# frozen_string_literal: true

# Anonymizes all buyer PII for a given email address across all tables.
# Designed for guest buyers who have no User record — triggered from the
# admin purchase page. Also callable from Rails console:
#
#   GdprBuyerErasureService.new("buyer@example.com", performed_by: User.find(ADMIN_ID)).perform!
#
class GdprBuyerErasureService
  ANONYMIZED_EMAIL_DOMAIN = GdprDataErasureService::ANONYMIZED_EMAIL_DOMAIN
  ANONYMIZED_NAME = GdprDataErasureService::ANONYMIZED_NAME
  ANONYMIZED_VALUE = GdprDataErasureService::ANONYMIZED_VALUE

  attr_reader :email, :performed_by, :counts

  def initialize(email, performed_by:)
    @email = email.to_s.strip.downcase
    @performed_by = performed_by
    @counts = Hash.new(0)
  end

  def perform!
    raise ArgumentError, "Email is required" if email.blank?

    # If this email belongs to a registered user, use the full account erasure instead.
    if (user = User.alive.find_by(email: email))
      raise ArgumentError, "This email belongs to user ##{user.id} (#{user.username}). Use GdprDataErasureService for account holders."
    end

    anonymized_email = generate_anonymized_email

    ActiveRecord::Base.transaction do
      anonymize_purchases!(anonymized_email)
      anonymize_events!
      anonymize_audience_members!(anonymized_email)
      anonymize_followers!(anonymized_email)
      anonymize_carts!(anonymized_email)
      anonymize_gifts!(anonymized_email)
      anonymize_imported_customers!(anonymized_email)
      anonymize_sent_post_emails!(anonymized_email)
      anonymize_blocked_customer_objects!(anonymized_email)
      anonymize_signup_events!
      anonymize_service_charges!
      anonymize_charges!
      anonymize_dispute_evidences!
      anonymize_purchase_custom_fields!
      anonymize_credit_cards!
      log_erasure!
    end

    { success: true, email: email, anonymized_to: anonymized_email, counts: counts }
  rescue => e
    Rails.logger.error("GDPR buyer erasure failed for #{email}: #{e.message}")
    raise
  end

  private
    def generate_anonymized_email
      digest = Digest::SHA256.hexdigest(email)[0..11]
      "buyer-#{digest}@#{ANONYMIZED_EMAIL_DOMAIN}"
    end

    def anonymize_purchases!(anonymized_email)
      # Collect credit card IDs before anonymizing
      purchase_credit_card_ids = Purchase.where(email: email).where.not(credit_card_id: nil).distinct.pluck(:credit_card_id)
      @credit_card_ids_from_purchases = purchase_credit_card_ids

      counts[:purchases] = Purchase.where(email: email).update_all(
        email: anonymized_email,
        full_name: ANONYMIZED_NAME,
        street_address: nil,
        city: nil,
        state: nil,
        zip_code: nil,
        country: nil,
        ip_address: nil,
        ip_country: nil,
        ip_state: nil,
        browser_guid: nil,
        stripe_fingerprint: nil,
        stripe_card_id: nil,
        card_type: nil,
        card_visual: nil,
        card_bin: nil,
        card_country: nil,
        card_expiry_month: nil,
        card_expiry_year: nil,
        credit_card_zipcode: nil,
        session_id: nil,
        referrer: nil,
        custom_fields: nil,
      )
    end

    def anonymize_events!
      counts[:events] = Event.where(email: email).update_all(
        email: nil,
        ip_address: nil,
        ip_country: nil,
        card_visual: nil,
        fingerprint: nil,
        billing_zip: nil,
      )
    end

    def anonymize_audience_members!(anonymized_email)
      counts[:audience_members] = AudienceMember.where(email: email).update_all(
        email: anonymized_email,
        details: nil,
      )
    end

    def anonymize_followers!(anonymized_email)
      counts[:followers] = Follower.where(email: email).update_all(
        email: anonymized_email,
      )
    end

    def anonymize_carts!(anonymized_email)
      counts[:carts] = Cart.where(email: email).update_all(
        email: anonymized_email,
        ip_address: nil,
        browser_guid: nil,
      )
    end

    def anonymize_gifts!(anonymized_email)
      counts[:gifts_as_giftee] = Gift.where(giftee_email: email).update_all(giftee_email: anonymized_email)
      counts[:gifts_as_gifter] = Gift.where(gifter_email: email).update_all(gifter_email: anonymized_email)
    end

    def anonymize_imported_customers!(anonymized_email)
      counts[:imported_customers] = ImportedCustomer.where(email: email).update_all(
        email: anonymized_email,
      )
    end

    def anonymize_sent_post_emails!(anonymized_email)
      counts[:sent_post_emails] = SentPostEmail.where(email: email).update_all(
        email: anonymized_email,
      )
    end

    def anonymize_blocked_customer_objects!(anonymized_email)
      counts[:blocked_customer_objects] = BlockedCustomerObject.where(buyer_email: email).update_all(
        buyer_email: anonymized_email,
      )
    end

    def anonymize_signup_events!
      counts[:signup_events] = SignupEvent.where(email: email).update_all(
        email: nil,
        ip_address: nil,
        ip_country: nil,
        ip_state: nil,
        billing_zip: nil,
        card_type: nil,
        card_visual: nil,
        fingerprint: nil,
        browser_fingerprint: nil,
        browser_plugins: nil,
        browser_guid: nil,
      )
    end

    def anonymize_service_charges!
      # ServiceCharge is linked to User, not email. Guest buyers have no
      # User record, so there are no service charges to anonymize.
    end

    def anonymize_charges!
      purchase_ids = Purchase.where(email: generate_anonymized_email).pluck(:id)
      return if purchase_ids.empty?

      charge_ids = ChargePurchase.where(purchase_id: purchase_ids).distinct.pluck(:charge_id)
      return if charge_ids.empty?

      counts[:charges] = Charge.where(id: charge_ids).update_all(
        payment_method_fingerprint: nil,
      )
    end

    def anonymize_dispute_evidences!
      counts[:dispute_evidences] = DisputeEvidence.where(customer_email: email).update_all(
        customer_email: nil,
        customer_name: nil,
        customer_purchase_ip: nil,
        billing_address: nil,
        shipping_address: nil,
      )
    end

    def anonymize_purchase_custom_fields!
      purchase_ids = Purchase.where(email: generate_anonymized_email).pluck(:id)
      return if purchase_ids.empty?

      counts[:purchase_custom_fields] = PurchaseCustomField.where(purchase_id: purchase_ids).update_all(
        value: ANONYMIZED_VALUE,
      )
    end

    def anonymize_credit_cards!
      credit_card_ids = @credit_card_ids_from_purchases || []
      return if credit_card_ids.empty?

      # Only anonymize credit cards not owned by any user (guest cards)
      user_owned_ids = User.where(credit_card_id: credit_card_ids).pluck(:credit_card_id)
      guest_card_ids = credit_card_ids - user_owned_ids
      return if guest_card_ids.empty?

      counts[:credit_cards] = CreditCard.where(id: guest_card_ids).update_all(
        card_type: ANONYMIZED_VALUE,
        visual: ANONYMIZED_VALUE,
        card_bin: nil,
        card_country: nil,
        expiry_month: nil,
        expiry_year: nil,
        stripe_fingerprint: nil,
        stripe_card_id: nil,
        stripe_customer_id: nil,
        braintree_customer_id: nil,
        paypal_billing_agreement_id: nil,
        processor_payment_method_id: nil,
        funding_type: nil,
        json_data: nil,
      )
    end

    def log_erasure!
      # Log on each seller whose purchases were affected
      seller_ids = Purchase.where(email: generate_anonymized_email).distinct.pluck(:seller_id)
      seller_ids.each do |seller_id|
        User.find_by(id: seller_id)&.comments&.create!(
          author_id: performed_by.id,
          author_name: performed_by.name || performed_by.email,
          comment_type: Comment::COMMENT_TYPE_NOTE,
          content: "GDPR buyer erasure performed for a guest buyer. " \
                   "All buyer PII anonymized across #{counts.values.sum} records. " \
                   "Performed by #{performed_by.email}."
        )
      end
    end
end
