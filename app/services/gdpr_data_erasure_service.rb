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
    @unreachable_guardian_person_ids = []
  end

  def perform!
    original_email = @user.email
    credit_card_ids = credit_card_ids_for_erasure
    # Read before the transaction so the Stripe deletion below has the accounts to hand. The values
    # would survive the transaction unchanged, but resolving them up front keeps the deletion
    # independent of what erasure does to the account in between.
    #
    # Only the ACCOUNTS are resolved here. Which Persons those accounts hold is resolved later,
    # inside the sync lock, because a concurrent guardian sync can create one after this point.
    stripe_account_ids = guardian_stripe_account_ids_for_erasure

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
    retained_guardian_person_ids = delete_guardian_stripe_persons!(stripe_account_ids)

    if retained_guardian_person_ids.any? || @unreachable_guardian_person_ids.any?
      # Our own copy is erased, but a third party's identity data is still at the processor. Saying
      # "success" here is what let a failed guardian deletion pass for a completed erasure, so the
      # request stays open until the retry job clears it.
      #
      # The note is written here rather than where the condition is detected, because it must only
      # claim an incomplete erasure once the erasure itself committed.
      record_incomplete_erasure_note!(retained_guardian_person_ids)

      return {
        success: false,
        error: incomplete_erasure_error(retained_guardian_person_ids),
        summary: erasure_summary
      }
    end

    { success: true, summary: erasure_summary }
  rescue => e
    Rails.logger.error("GDPR erasure failed for user #{@user.id}: #{e.message}")
    { success: false, error: e.message }
  end

  private
    # Durable record of what is still at Stripe, on the account rather than only in Sentry: whoever
    # re-checks the request needs to know which Persons to look for after the alert has aged out.
    def record_incomplete_erasure_note!(retained_guardian_person_ids)
      stuck_person_ids = (retained_guardian_person_ids + @unreachable_guardian_person_ids).uniq

      @user.add_payout_note(
        content: "GDPR erasure incomplete: guardian Stripe person(s) #{stuck_person_ids.join(', ')} " \
                 "still held at Stripe. #{incomplete_erasure_error(retained_guardian_person_ids)}",
        seller_visible: false
      )
    rescue => e
      Rails.logger.error("GDPR: failed to record incomplete-erasure note for user #{@user.id}: #{e.message}")
      ErrorNotifier.notify(e)
    end

    # Two shapes of incomplete, and they need different instructions: a failed delete is being
    # retried and will clear itself, while a Person with no resolvable account has nothing retrying
    # it and needs someone to find the account at Stripe by hand.
    def incomplete_erasure_error(retained_guardian_person_ids)
      parts = []
      if retained_guardian_person_ids.any?
        parts << "#{retained_guardian_person_ids.size} guardian record(s) could not be deleted at " \
                 "Stripe and are being retried in the background"
      end
      if @unreachable_guardian_person_ids.any?
        parts << "#{@unreachable_guardian_person_ids.size} guardian record(s) have no resolvable " \
                 "Stripe account and must be deleted at Stripe manually"
      end

      "Erasure incomplete: #{parts.join('; ')}. Re-check before confirming the request as fulfilled."
    end

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
    # skip the rest.
    #
    # A failure is not final here. Logging it and returning success would report an erasure that did
    # not reach the processor, so each failure is handed to DeleteGuardianStripePersonJob to retry
    # and counted, and the caller reports the erasure as incomplete until that count is zero.
    #
    # Returns the Person ids still at Stripe.
    def delete_guardian_stripe_persons!(stripe_account_ids)
      return [] if stripe_account_ids.empty?

      # A false return means Stripe could not confirm the deletion because the ACCOUNT was missing,
      # which is not evidence the Person is gone. Erasure tries every account the seller ever held,
      # so one account answering "no such account" is expected and harmless — what matters is
      # whether ANY account confirmed the delete. Tracked per Person id and reconciled below.
      confirmed = Set.new
      unconfirmed = {}
      retained = []

      stripe_account_ids.each do |stripe_account_id|
        # One lock per account, held across the scan AND the deletes for that account. Guardian sync
        # is the other writer of legal-guardian Persons here, and the two must be ordered: a sync
        # that read the guardian before this erasure anonymized it can still be mid-flight, and it
        # creates its Person after any snapshot taken outside this lock. Scanning inside the lock is
        # what makes that Person visible to the delete instead of surviving a "successful" erasure.
        #
        # Sequential rather than nested, because a sync only touches the one account it was called
        # with. Past the anonymize above no sync can start a create at all — StripeGuardianManager
        # re-checks the reloaded guardian and an anonymized row is never complete — so ordering
        # against the syncs already holding a lock is the whole requirement.
        StripeGuardianManager.with_account_sync_lock(stripe_account_id, "erase guardian persons") do
          # Re-read the guardians inside the lock. A sync that finished while erasure waited may have
          # written a stripe_person_id the snapshot above does not have, and that id is a handle to
          # PII this erasure is responsible for.
          StripeGuardianManager.stripe_person_ids_for_erasure(@user.guardians.reload.to_a, stripe_account_id)
                               .each do |stripe_person_id|
            if StripeGuardianManager.delete_person_by_id(stripe_person_id, stripe_account_id)
              confirmed << stripe_person_id
            else
              unconfirmed[stripe_person_id] = stripe_account_id
            end
          rescue => e
            Rails.logger.error("GDPR: Failed to delete Stripe guardian person for user #{@user.id}: #{e.message}")
            ErrorNotifier.notify(e)
            DeleteGuardianStripePersonJob.perform_async(stripe_person_id, stripe_account_id, @user.id)
            retained << stripe_person_id
          end
        end
      rescue StripeGuardianManager::SyncLockUnavailable => e
        # Deleting without the lock would race the very sync the lock exists to order, and skipping
        # the account silently would report a complete erasure. So the recorded Persons go to the
        # retry job instead — by then the guardian is anonymized, so no sync can create another and
        # the job needs no lock of its own. That also fails the erasure, which is the point: it is
        # not fulfilled until the retry confirms the delete.
        #
        # Only recorded ids can be handed over; a Person reachable solely by scan needs the scan,
        # which is what did not happen here. The failed erasure is what gets someone to re-run it.
        Rails.logger.error("GDPR: could not lock Stripe account #{stripe_account_id} for user #{@user.id}: #{e.message}")
        ErrorNotifier.notify(e)
        @user.guardians.filter_map(&:stripe_person_id).each do |stripe_person_id|
          DeleteGuardianStripePersonJob.perform_async(stripe_person_id, stripe_account_id, @user.id)
          retained << stripe_person_id
        end
      end

      # Nothing confirmed this Person deleted anywhere, so it may still stand at Stripe. Retry it
      # rather than letting an unverified delete pass for a completed erasure.
      unconfirmed.except(*confirmed, *retained).each do |stripe_person_id, stripe_account_id|
        message = "GDPR: could not confirm deletion of guardian Stripe person #{stripe_person_id} " \
                  "for user #{@user.id}: no account acknowledged the delete"
        Rails.logger.error(message)
        ErrorNotifier.notify(message)
        DeleteGuardianStripePersonJob.perform_async(stripe_person_id, stripe_account_id, @user.id)
        retained << stripe_person_id
      end

      retained.uniq
    end

    # The Stripe accounts a guardian Person of this seller may live on.
    #
    # Deliberately NOT User#stripe_account: that is scoped to charge_processor_alive, and switching
    # payout method, changing country, or connecting Stripe Connect all call
    # MerchantAccount#delete_charge_processor_account!, which marks the account dead here and never
    # deletes it at Stripe. Resolving only the live account would leave the guardian's Person — an
    # adult's name, date of birth, address and tax id — at Stripe while erasure reported success. The
    # merchant id is a column and survives that local delete (only meta is cleared), so a dead row is
    # still a usable handle.
    #
    # Every candidate account is tried rather than guessing which one holds the Person: a guardian
    # keeps one stripe_person_id, and a re-onboarded seller's later sync overwrites it, so the id
    # alone cannot say which account it came from.
    def guardian_stripe_account_ids_for_erasure
      guardians = @user.guardians.to_a
      return [] if guardians.empty?

      stripe_account_ids = @user.merchant_accounts.stripe
                                .reject(&:is_a_stripe_connect_account?)
                                .filter_map(&:charge_processor_merchant_id)
                                .uniq

      if stripe_account_ids.empty?
        # A recorded person id with no resolvable account is proof Stripe holds a copy we have no
        # handle for, and nothing here can retry it — there is no account id to retry against. So it
        # is recorded as unreachable rather than dropped: an empty list would read as "nothing to
        # delete" and let perform! report the erasure complete. Guardians with no recorded person id
        # were never synced, so there is nothing at Stripe to reach.
        @unreachable_guardian_person_ids = guardians.filter_map(&:stripe_person_id)

        if @unreachable_guardian_person_ids.any?
          message = "GDPR: user #{@user.id} has #{@unreachable_guardian_person_ids.size} guardian " \
                    "Stripe person(s) but no resolvable Stripe account id, so their details were " \
                    "NOT deleted at Stripe and cannot be retried automatically"
          Rails.logger.error(message)
          ErrorNotifier.notify(message)
        end
      end

      stripe_account_ids
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
