# frozen_string_literal: true

class GdprBuyerErasureService
  ANONYMIZED_EMAIL_DOMAIN = GdprDataErasureService::ANONYMIZED_EMAIL_DOMAIN
  ANONYMIZED_NAME = GdprDataErasureService::ANONYMIZED_NAME
  ANONYMIZED_VALUE = GdprDataErasureService::ANONYMIZED_VALUE

  # Errors raised when a statement contends for a row lock or exceeds the
  # configured statement timeout. On very old guest purchases the erasure can
  # contend with other long-running writers on broadly-shared tables (events,
  # purchases). We treat these as non-critical and skip the affected step
  # rather than failing the whole erasure (see #perform!).
  TIMEOUT_ERRORS = [
    ActiveRecord::LockWaitTimeout,
    ActiveRecord::StatementTimeout,
    ActiveRecord::QueryCanceled,
  ].freeze

  attr_reader :email, :performed_by, :counts, :skipped

  def initialize(email, performed_by:)
    @email = email.to_s.strip.downcase
    @performed_by = performed_by
    @counts = Hash.new(0)
    @skipped = []
  end

  def perform!
    raise ArgumentError, "Email is required" if email.blank?

    if (user = User.find_by(email: email))
      raise ArgumentError, "This email belongs to user ##{user.id}. Use GdprDataErasureService for account holders."
    end

    registered_purchase_count = Purchase.where(email: email).where.not(purchaser_id: nil).count
    if registered_purchase_count > 0
      raise ArgumentError, "This email is associated with #{registered_purchase_count} purchase(s) belonging to registered users. Erase those account holders with GdprDataErasureService first."
    end

    @anonymized_email = generate_anonymized_email

    # Match the anonymized email too, so a re-run after a partial failure can
    # still rebuild @purchase_ids: anonymize_purchases! rewrites the buyer's
    # purchase email to @anonymized_email (deterministic), and the downstream
    # steps that key off purchase ids (events, charges, custom fields) would
    # otherwise have no way to locate those purchases on a second run.
    purchases = Purchase.where(purchaser_id: nil, email: [email, @anonymized_email])
    @purchase_ids = purchases.pluck(:id)
    @credit_card_ids = purchases.where.not(credit_card_id: nil).distinct.pluck(:credit_card_id)
    candidate_browser_guids = purchases.where.not(browser_guid: nil).distinct.pluck(:browser_guid)
    shared_browser_guids = candidate_browser_guids.any? ? Purchase.where(browser_guid: candidate_browser_guids).where.not(id: @purchase_ids).distinct.pluck(:browser_guid) : []
    @browser_guids = candidate_browser_guids - shared_browser_guids
    @seller_ids = purchases.distinct.pluck(:seller_id)

    # Best-effort, per-step erasure. We intentionally do NOT wrap these in a
    # single transaction: a lock-wait timeout on one broadly-contended table
    # (e.g. events) would otherwise roll back every other table too, leaving
    # the buyer's PII fully intact — the failure mode reported in #438. Each
    # step runs and commits independently; if a step times out we record it as
    # skipped and move on. The erasure does its best across everything it can
    # lock, and the admin sees which (if any) tables were deferred.
    {
      purchases: -> { anonymize_purchases! },
      events: -> { anonymize_events! },
      audience_members: -> { anonymize_audience_members! },
      followers: -> { anonymize_followers! },
      carts: -> { anonymize_carts! },
      gifts: -> { anonymize_gifts! },
      imported_customers: -> { anonymize_imported_customers! },
      sent_post_emails: -> { anonymize_sent_post_emails! },
      blocked_customer_objects: -> { anonymize_blocked_customer_objects! },
      signup_events: -> { anonymize_signup_events! },
      charges: -> { anonymize_charges! },
      dispute_evidences: -> { anonymize_dispute_evidences! },
      purchase_custom_fields: -> { anonymize_purchase_custom_fields! },
      credit_cards: -> { anonymize_credit_cards! },
      discover_searches: -> { anonymize_discover_searches! },
      utm_link_visits: -> { anonymize_utm_link_visits! },
    }.each do |step_name, step|
      run_step(step_name, &step)
    end

    log_erasure!

    { success: true, email: email, anonymized_to: @anonymized_email, counts: counts, skipped: skipped }
  rescue ArgumentError
    raise
  rescue => e
    Rails.logger.error("GDPR buyer erasure failed for #{@anonymized_email || '[no anonymized email yet]'}: #{e.message}")
    raise
  end

  private
    # Runs a single anonymization step, silencing lock-wait/statement timeouts
    # so one contended table can't abort the rest of the erasure. Non-timeout
    # errors still propagate (they indicate a real bug, not contention).
    def run_step(step_name)
      yield
    rescue *TIMEOUT_ERRORS => e
      skipped << step_name
      Rails.logger.warn("GDPR buyer erasure: step '#{step_name}' timed out for #{@anonymized_email} and was skipped (non-critical): #{e.class}")
    end

    def generate_anonymized_email
      digest = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, email)[0..15]
      "buyer-#{digest}@#{ANONYMIZED_EMAIL_DOMAIN}"
    end

    def anonymize_purchases!
      counts[:purchases] = Purchase.where(id: @purchase_ids).update_all(
        email: @anonymized_email,
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
      return if @purchase_ids.empty?

      counts[:events] = Event.where(purchase_id: @purchase_ids).update_all(
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

    def anonymize_audience_members!
      conflict_seller_ids = AudienceMember.where(email: @anonymized_email).pluck(:seller_id)
      if conflict_seller_ids.any?
        conflicting_members = AudienceMember.where(email: email, seller_id: conflict_seller_ids)
        deleted_member_ids = conflicting_members.ids
        conflicting_members.delete_all
        deleted_member_ids.each do |member_id|
          ElasticsearchIndexerWorker.perform_async("delete", { "record_id" => member_id, "class_name" => "AudienceMember" })
        end
      end

      anonymized_attributes = {
        email: @anonymized_email,
        details: nil,
        customer: false,
        follower: false,
        affiliate: false,
        min_paid_cents: nil,
        max_paid_cents: nil,
        min_created_at: nil,
        max_created_at: nil,
        min_purchase_created_at: nil,
        max_purchase_created_at: nil,
        follower_created_at: nil,
        min_affiliate_created_at: nil,
        max_affiliate_created_at: nil,
      }
      members = AudienceMember.where(email: email).to_a
      counts[:audience_members] = AudienceMember.where(id: members.map(&:id)).update_all(anonymized_attributes)
      # The indexer worker re-reads rows from a possibly-lagging replica; passing the
      # document body inline guarantees the pre-erasure PII can never be re-indexed.
      members.each do |member|
        member.assign_attributes(anonymized_attributes)
        ElasticsearchIndexerWorker.perform_async(
          "index",
          { "record_id" => member.id, "class_name" => "AudienceMember", "body" => member.as_indexed_json },
        )
      end
    end

    def anonymize_followers!
      conflict_followed_ids = Follower.where(email: @anonymized_email).pluck(:followed_id)
      Follower.where(email: email, followed_id: conflict_followed_ids).delete_all if conflict_followed_ids.any?
      counts[:followers] = Follower.where(email: email).update_all(
        email: @anonymized_email,
      )
    end

    def anonymize_carts!
      counts[:carts] = Cart.where(email: email).update_all(
        email: @anonymized_email,
        ip_address: nil,
        browser_guid: nil,
      )
    end

    def anonymize_gifts!
      counts[:gifts_as_giftee] = Gift.where(giftee_email: email).update_all(giftee_email: @anonymized_email)
      counts[:gifts_as_gifter] = Gift.where(gifter_email: email).update_all(gifter_email: @anonymized_email)
    end

    def anonymize_imported_customers!
      counts[:imported_customers] = ImportedCustomer.where(email: email).update_all(
        email: @anonymized_email,
      )
    end

    def anonymize_sent_post_emails!
      conflict_post_ids = SentPostEmail.where(email: @anonymized_email).pluck(:post_id)
      SentPostEmail.where(email: email, post_id: conflict_post_ids).delete_all if conflict_post_ids.any?
      counts[:sent_post_emails] = SentPostEmail.where(email: email).update_all(
        email: @anonymized_email,
      )
    end

    def anonymize_blocked_customer_objects!
      email_object_type = BlockedCustomerObject::SUPPORTED_OBJECT_TYPES[:email]

      conflict_seller_ids = BlockedCustomerObject.where(object_type: email_object_type, object_value: @anonymized_email).pluck(:seller_id)
      if conflict_seller_ids.any?
        BlockedCustomerObject.where(object_type: email_object_type, object_value: email, seller_id: conflict_seller_ids).delete_all
      end

      affected_ids = BlockedCustomerObject.where(buyer_email: email)
                                          .or(BlockedCustomerObject.where(object_type: email_object_type, object_value: email))
                                          .distinct
                                          .pluck(:id)

      BlockedCustomerObject.where(id: affected_ids, buyer_email: email).update_all(buyer_email: @anonymized_email)
      BlockedCustomerObject.where(id: affected_ids, object_type: email_object_type, object_value: email).update_all(object_value: @anonymized_email)

      counts[:blocked_customer_objects] = affected_ids.size
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

    def anonymize_charges!
      return if @purchase_ids.empty?

      charge_ids = ChargePurchase.where(purchase_id: @purchase_ids).distinct.pluck(:charge_id)
      return if charge_ids.empty?

      shared_charge_ids = ChargePurchase
        .where(charge_id: charge_ids)
        .where.not(purchase_id: @purchase_ids)
        .distinct
        .pluck(:charge_id)
      exclusive_charge_ids = charge_ids - shared_charge_ids
      return if exclusive_charge_ids.empty?

      counts[:charges] = Charge.where(id: exclusive_charge_ids).update_all(
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
      return if @purchase_ids.empty?

      counts[:purchase_custom_fields] = PurchaseCustomField.where(purchase_id: @purchase_ids).update_all(
        value: ANONYMIZED_VALUE,
      )
    end

    def anonymize_credit_cards!
      return if @credit_card_ids.empty?

      user_owned_ids = User.where(credit_card_id: @credit_card_ids).pluck(:credit_card_id)
      shared_with_other_buyers_ids = Purchase
        .where(credit_card_id: @credit_card_ids)
        .where.not(id: @purchase_ids)
        .distinct
        .pluck(:credit_card_id)
      guest_card_ids = @credit_card_ids - user_owned_ids - shared_with_other_buyers_ids
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

    def anonymize_discover_searches!
      return if @browser_guids.empty?

      counts[:discover_searches] = DiscoverSearch.where(browser_guid: @browser_guids).update_all(
        ip_address: nil,
        browser_guid: nil,
      )
    end

    def anonymize_utm_link_visits!
      return if @browser_guids.empty?

      counts[:utm_link_visits] = UtmLinkVisit.where(browser_guid: @browser_guids).update_all(
        ip_address: ANONYMIZED_VALUE,
        browser_guid: ANONYMIZED_VALUE,
        user_agent: nil,
      )
    end

    def log_erasure!
      skipped_note = skipped.any? ? " #{skipped.size} table(s) were skipped due to lock-wait timeouts and may retain data: #{skipped.join(', ')}." : ""

      @seller_ids.each do |seller_id|
        seller = User.find_by(id: seller_id)
        next unless seller

        seller.comments.create!(
          author_id: performed_by.id,
          author_name: performed_by.name || performed_by.email,
          comment_type: Comment::COMMENT_TYPE_NOTE,
          content: "GDPR buyer erasure performed for a guest buyer. " \
                   "Buyer PII anonymized across #{counts.values.sum} records.#{skipped_note} " \
                   "Performed by #{performed_by.email}."
        )
      rescue => e
        Rails.logger.error("GDPR buyer erasure log failed for #{@anonymized_email} on seller #{seller_id}: #{e.message}")
      end
    rescue => e
      Rails.logger.error("GDPR buyer erasure log_erasure! unexpected failure for #{@anonymized_email}: #{e.message}")
    end
end
