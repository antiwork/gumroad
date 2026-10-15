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
    reset_run_state!
  end

  def perform!
    # A failed run rolls back the rows but not this object: @user would still hold the anonymized
    # email and deleted_at, and a retry would then skip deactivation and every email-keyed step.
    @user.reload
    reset_run_state!

    # Only the confirmed address: unconfirmed_email was typed in but never proven to be theirs, so
    # matching other people's rows on it could erase a stranger's data.
    original_email = @user.email
    credit_card_ids = credit_card_ids_for_erasure
    # Read before anything below nulls the browser_guid columns this attribution is built from.
    guest_cart_browser_guids = exclusive_browser_guids(original_email)
    # Read before the transaction so the Stripe deletion below has the accounts to hand. The values
    # would survive the transaction unchanged, but resolving them up front keeps the deletion
    # independent of what erasure does to the account in between.
    #
    # Only the ACCOUNTS are resolved here. Which Persons those accounts hold is resolved later,
    # inside the sync lock, because a concurrent guardian sync can create one after this point.
    stripe_account_ids = guardian_stripe_account_ids_for_erasure

    ActiveRecord::Base.transaction do
      @products_deleted = deactivate_account!
      # Outside deactivate_account!, which returns early for an already-closed account: one closed
      # before closure revoked third-party access still holds those tokens. Flags are cleared before
      # the anonymize that overwrites the email gumroad_account? reads.
      @user.revoke_all_oauth_access!
      @user.clear_team_member_flags!
      anonymized_email = anonymize_user_pii!
      anonymize_compliance_info!
      delete_device_records!
      anonymize_carts!(anonymized_email:, original_email:, guest_cart_browser_guids:)
      anonymize_credit_cards!(credit_card_ids)
      anonymize_buyer_purchases!(anonymized_email:, original_email:)
      erase_email_keyed_records!(anonymized_email:, original_email:)
      anonymize_linked_followers!(anonymized_email)
      log_erasure!
      # Every run, not only the one that rewrote the rows: a rerun is what writes the documents an
      # earlier run recorded but could not write.
      AfterCommitEverywhere.after_commit { write_pending_audience_search_documents! }
    end
    # Set only once the anonymize has committed, because it is what makes an unfinished Stripe
    # deletion a retained-PII problem. A failure BEFORE this point erased nothing, and remediating
    # there would delete the guardian Person of an account that is still live and still needs it.
    @local_erasure_committed = true

    remove_profile_assets!
    # Re-resolved after the commit and unioned with the snapshot, because an account created while
    # the transaction ran is absent from the snapshot and a sync can put a guardian Person on it.
    # Safe to trust this second read as final: past the anonymize no sync can create a Person at all
    # (StripeGuardianManager re-checks the reloaded guardian under the lock, and an anonymized row is
    # never complete), so no third account can appear behind this one. The snapshot is still unioned
    # in rather than replaced — erasure soft-deletes the account holder, so a row the first read
    # resolved may no longer resolve here.
    #
    # Gated on the seller having a guardian at all. The whole guardian surface — the per-account sync
    # lock, the Person scan, the unscanned-account bookkeeping — exists to chase a Person only a
    # guardian sync can have created, and a seller with no guardian row has never run one. Without
    # the gate every erasure on the platform took the sync lock for nothing, and a Redis outage then
    # failed those erasures with a note telling a human to hand-scan Stripe for a guardian that
    # never existed.
    if @user.guardians.exists?
      stripe_account_ids = (stripe_account_ids | resolve_guardian_stripe_account_ids)
    end
    retained_guardian_person_ids = delete_guardian_stripe_persons!(stripe_account_ids)

    if retained_guardian_person_ids.any? || @unreachable_guardian_person_ids.any? ||
        @unscanned_guardian_account_ids.any?
      # Our own copy is erased, but a third party's identity data is still at the processor. Saying
      # "success" here is what let a failed guardian deletion pass for a completed erasure, so the
      # request stays open until the retry job clears it.
      #
      # The note is written here rather than where the condition is detected, because it must only
      # claim an incomplete erasure once the erasure itself committed.
      record_incomplete_erasure_note!(retained_guardian_person_ids)

      return {
        success: false,
        error: [incomplete_erasure_error(retained_guardian_person_ids), @search_index_error].compact.join(" "),
        summary: erasure_summary
      }
    end
    return { success: false, error: @search_index_error, summary: erasure_summary } if @search_index_error

    { success: true, summary: erasure_summary }
  rescue => e
    Rails.logger.error("GDPR erasure failed for user #{@user.id}: #{e.message}")
    # Last resort for the same problem the branch above handles: our copy is already anonymized and
    # something on the way to Stripe raised, so a guardian Person may still stand there with nothing
    # retrying it. Only reached when the failure escaped delete_guardian_stripe_persons!'s own
    # per-person and per-account rescues entirely.
    remediate_guardian_persons_after_failure!(stripe_account_ids)
    { success: false, error: e.message }
  end

  private
    def reset_run_state!
      @products_deleted = 0
      @unreachable_guardian_person_ids = []
      @unscanned_guardian_account_ids = []
      @scanned_guardian_account_ids = []
      @local_erasure_committed = false
      @counts = Hash.new(0)
      @search_index_error = nil
    end

    # Hands every recorded guardian Person to the retry job and leaves the durable note. Selects on
    # the recorded stripe_person_id, which anonymize! deliberately does not clear — it is the only
    # handle left once the identifying columns are nil.
    def remediate_guardian_persons_after_failure!(stripe_account_ids)
      return unless @local_erasure_committed
      return if stripe_account_ids.blank?

      # Any account this failure prevented us from finishing a scan on. Independent of the person-id
      # check below: a guardian with no recorded id can still have a Person at Stripe, and the scan
      # that raised was the only thing that could have found it.
      @unscanned_guardian_account_ids |= (stripe_account_ids - @scanned_guardian_account_ids)

      person_ids = @user.guardians.reload.filter_map(&:stripe_person_id).uniq

      return if person_ids.empty? && @unscanned_guardian_account_ids.empty?

      # The note is written BEFORE the enqueue, not after. perform_async needs Redis, and a Redis
      # outage is the headline case this remediation exists for — enqueueing first meant the very
      # first perform_async raised, jumped to the rescue below, and the note never got written. That
      # is the "nothing durable to check" outcome, reached precisely when it matters most. MySQL is
      # up here: the erasure transaction committed a moment ago.
      record_incomplete_erasure_note!(person_ids)

      # Per-enqueue rescue for the same reason: one unreachable Sidekiq must not skip the rest, and
      # the note above is already safe on disk either way.
      person_ids.each do |stripe_person_id|
        stripe_account_ids.each do |stripe_account_id|
          DeleteGuardianStripePersonJob.perform_async(stripe_person_id, stripe_account_id, @user.id)
        rescue => e
          Rails.logger.error("GDPR: could not enqueue guardian person retry for user #{@user.id}: #{e.message}")
          ErrorNotifier.notify(e)
        end
      end
    rescue => e
      # Never let the remediation replace the original failure the caller is reporting.
      Rails.logger.error("GDPR: failed to remediate guardian Stripe persons for user #{@user.id}: #{e.message}")
      ErrorNotifier.notify(e)
    end

    # Durable record of what is still at Stripe, on the account rather than only in Sentry: whoever
    # re-checks the request needs to know which Persons to look for after the alert has aged out.
    def record_incomplete_erasure_note!(retained_guardian_person_ids)
      stuck_person_ids = (retained_guardian_person_ids + @unreachable_guardian_person_ids).uniq
      subject = if stuck_person_ids.any?
        "guardian Stripe person(s) #{stuck_person_ids.join(', ')} still held at Stripe"
      else
        # No id to name: the account could not be scanned, so which Persons it holds is exactly what
        # is unknown. Naming the account is the only actionable thing here, and it is what the note
        # exists for.
        "guardian Stripe person(s) possibly still held at Stripe on account(s) " \
          "#{@unscanned_guardian_account_ids.uniq.join(', ')}"
      end

      @user.add_payout_note(
        content: "GDPR erasure incomplete: #{subject}. " \
                 "#{incomplete_erasure_error(retained_guardian_person_ids)}",
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
      if @unscanned_guardian_account_ids.any?
        # A third shape: nothing is known to be retained, but the account was never fully listed —
        # the lock could not be taken, or the Person pages ran out partway. Worded as unverified
        # rather than retained; that is what someone re-checking has to go and establish.
        parts << "#{@unscanned_guardian_account_ids.uniq.size} Stripe account(s) could not be " \
                 "fully scanned for guardian records and must be checked at Stripe manually"
      end

      "Erasure incomplete: #{parts.join('; ')}. Re-check before confirming the request as fulfilled."
    end

    def deactivate_account!
      return 0 if @user.deleted?

      products_deleted = @user.links.visible.count

      # Skip balance validation for GDPR erasure. We are legally obligated
      # to erase regardless of outstanding balance (Article 17).
      @user.update!(
        deleted_at: Time.current,
        username: nil,
        credit_card_id: nil,
        payouts_paused_internally: true,
      )

      # The account's own cleanup, shared with the self-serve closure so an erasure cannot leave
      # behind records a closure removes. Validations are skipped: a legacy row that no longer
      # validates must not abort a mandated erasure (Article 17).
      @user.soft_delete_owned_records!
      @user.send(:cancel_active_subscriptions!)
      @user.invalidate_active_sessions!

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
        google_uid: nil,
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

      # A removed PayPal payout address is the same email PII as `payment_address` above, just moved
      # into json_data (Payment#invalidate_paypal_payout_address). update_columns bypasses the
      # attr_json accessor, so it has to be written through the model.
      if @user.invalidated_paypal_payout_address.present?
        @user.invalidated_paypal_payout_address = nil
        @user.save!(validate: false)
      end

      # Erasure soft-deletes the user rather than destroying it, so the association's
      # `dependent: :destroy` never runs and the platform uid/handle must be removed here.
      @user.social_connect_verifications.destroy_all
      @user.user_external_authentications.destroy_all
      @user.youtube_identity&.destroy
      @user.instagram_identity&.destroy
      @user.tiktok_identity&.destroy

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
          scan = StripeGuardianManager.stripe_person_ids_for_erasure(@user.guardians.reload.to_a, stripe_account_id)

          # A scan that did not reach every page fails the erasure even when every id it DID find
          # deletes cleanly. The unlisted Persons are precisely the ones with no recorded id — the
          # scan is the only thing that could have found them — so "everything I was handed was
          # deleted" is not evidence the account is clear, and there is no id to enqueue a retry for.
          @unscanned_guardian_account_ids << stripe_account_id unless scan.complete?

          scan.person_ids.each do |stripe_person_id|
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

        # Recorded only once the locked scan for this account returned. The rescue in perform! uses
        # it to tell an account whose Persons are known from one whose scan never ran: an exception
        # escaping mid-scan leaves an unrecorded Person discoverable by nothing else.
        @scanned_guardian_account_ids << stripe_account_id
      rescue StripeGuardianManager::SyncLockUnavailable => e
        # Deleting without the lock would race the very sync the lock exists to order, and skipping
        # the account silently would report a complete erasure. So the recorded Persons go to the
        # retry job instead — by then the guardian is anonymized, so no sync can create another and
        # the job needs no lock of its own. That also fails the erasure, which is the point: it is
        # not fulfilled until the retry confirms the delete.
        Rails.logger.error("GDPR: could not lock Stripe account #{stripe_account_id} for user #{@user.id}: #{e.message}")
        ErrorNotifier.notify(e)
        @user.guardians.filter_map(&:stripe_person_id).each do |stripe_person_id|
          # Per-enqueue rescue: the lock failed because Redis was unreachable often enough that
          # perform_async raises here too, and an escaping raise skipped the rest of the accounts and
          # every id after this one. Counted as retained either way — the delete is unconfirmed
          # whether or not we managed to queue the retry, and the erasure must fail on that.
          begin
            DeleteGuardianStripePersonJob.perform_async(stripe_person_id, stripe_account_id, @user.id)
          rescue => enqueue_error
            Rails.logger.error("GDPR: could not enqueue guardian person retry for user #{@user.id}: #{enqueue_error.message}")
            ErrorNotifier.notify(enqueue_error)
          end
          retained << stripe_person_id
        end

        # Recorded unscanned whether or not an id was handed over: the holder we lost the race to may
        # have created a Person without yet writing its id, which is exactly the case with nothing to
        # enqueue. So this fails the erasure on its own and names the account for a human to scan.
        @unscanned_guardian_account_ids << stripe_account_id
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

      stripe_account_ids = resolve_guardian_stripe_account_ids

      # A recorded person id we may not be able to reach. Keyed on a Stripe merchant row whose
      # merchant id we could not resolve rather than on the resolved set being EMPTY: a seller who
      # holds one unresolvable row alongside one good account gets a non-empty set, and the Person
      # recorded against the unresolvable one is then looked for on the good account, where Stripe
      # answers "no such person" — which delete_person_by_id reports as success. Absence on the
      # account we asked is not deletion from the account that holds it, so keying the check on the
      # empty set let exactly that erasure report itself fulfilled.
      #
      # Guardians with no recorded person id were never synced, so there is nothing at Stripe to
      # reach and no unreachable claim to make about them.
      if unresolvable_stripe_merchant_rows?
        @unreachable_guardian_person_ids = guardians.filter_map(&:stripe_person_id)

        if @unreachable_guardian_person_ids.any?
          message = "GDPR: user #{@user.id} has #{@unreachable_guardian_person_ids.size} guardian " \
                    "Stripe person(s) and at least one Stripe account we cannot resolve an id for, " \
                    "so their details may NOT have been deleted at Stripe and cannot be retried " \
                    "automatically"
          Rails.logger.error(message)
          ErrorNotifier.notify(message)
        end
      end

      stripe_account_ids
    end

    # Whether the seller holds a Stripe merchant account we cannot turn into an account id to talk
    # to. charge_processor_merchant_id is nullable and several jobs already filter on it being
    # present, so a row without one is a real state, not corruption — and it is a Stripe account a
    # guardian Person may sit on that this erasure has no way to reach.
    def unresolvable_stripe_merchant_rows?
      @user.merchant_accounts.reload.stripe
           .reject(&:is_a_stripe_connect_account?)
           .any? { |merchant_account| merchant_account.charge_processor_merchant_id.blank? }
    end

    # The raw account resolution, without the unreachable-Person bookkeeping above.
    #
    # Split out because perform! resolves twice — once before the transaction and once after — and
    # the "no resolvable account" branch has side effects (a Sentry notify, and marking every
    # recorded Person unreachable) that must fire on the caller's own terms rather than a second
    # time per call. It reloads the association: the second read exists precisely to see a merchant
    # account created after the first one.
    def resolve_guardian_stripe_account_ids
      @user.merchant_accounts.reload.stripe
           .reject(&:is_a_stripe_connect_account?)
           .filter_map(&:charge_processor_merchant_id)
           .uniq
    end

    def anonymize_carts!(anonymized_email:, original_email:, guest_cart_browser_guids:)
      attributes = { email: anonymized_email, ip_address: nil, browser_guid: nil }
      @counts[:carts] += @user.carts.update_all(attributes)

      # A checkout started before signing in leaves a cart with no user_id, keyed only by the
      # address typed into it.
      if email_keyed_erasure?(original_email:, anonymized_email:)
        @counts[:carts] += Cart.where(user_id: nil, email: original_email).update_all(attributes)
      end

      # A guest cart that never got an address can only be tied to this person by its device.
      return if guest_cart_browser_guids.empty?
      @counts[:carts] += Cart.where(user_id: nil, email: [nil, ""], browser_guid: guest_cart_browser_guids)
                             .update_all(ip_address: nil, browser_guid: nil)
    end

    # Browser GUIDs this person used that nobody else is known to have used. A GUID is a device
    # cookie, so one that also appears on another account's cart or purchase, or under another
    # address, is a shared device: an address-less guest cart on it could be anyone's.
    def exclusive_browser_guids(original_email)
      own_guids = [
        @user.carts.distinct.pluck(:browser_guid),
        Purchase.where(purchaser_id: @user.id).distinct.pluck(:browser_guid),
      ]
      if original_email.present?
        own_guids << Cart.where(user_id: nil, email: original_email).distinct.pluck(:browser_guid)
        own_guids << Purchase.where(purchaser_id: nil, email: original_email).distinct.pluck(:browser_guid)
      end
      own_guids = own_guids.flatten.compact_blank.uniq
      return [] if own_guids.empty?

      other_identity = [nil, "", original_email.presence].compact
      shared_guids = [
        Cart.where(browser_guid: own_guids).where.not(user_id: [nil, @user.id]),
        Cart.where(browser_guid: own_guids, user_id: nil).where.not(email: other_identity),
        Purchase.where(browser_guid: own_guids).where.not(purchaser_id: [nil, @user.id]),
        Purchase.where(browser_guid: own_guids, purchaser_id: nil).where.not(email: other_identity),
      ].flat_map { _1.distinct.pluck(:browser_guid) }

      own_guids - shared_guids
    end

    # False on a rerun, where the account already holds the anonymized address: matching on it
    # finds the rows erasure itself rewrote, and the conflict handling would then delete them.
    def email_keyed_erasure?(original_email:, anonymized_email:)
      original_email.present? && !original_email.casecmp?(anonymized_email)
    end

    def erase_email_keyed_records!(anonymized_email:, original_email:)
      return unless email_keyed_erasure?(original_email:, anonymized_email:)

      # Marketing-send dedupe rows, across every seller's posts. Nothing requires keeping them, so
      # they are deleted rather than rewritten. Served by index_sent_post_emails_on_email.
      @counts[:sent_post_emails] = SentPostEmail.where(email: original_email).delete_all

      audience_records = GdprAudienceRecordsAnonymizer.new(email: original_email, anonymized_email:)
      @counts[:audience_members] = audience_records.anonymize_audience_members!
      @counts[:followers] = audience_records.anonymize_followers!
      @counts[:imported_customers] = audience_records.anonymize_imported_customers!
      record_pending_audience_search_index!(
        reindex_ids: audience_records.pending_search_index_record_ids("index"),
        unindex_ids: audience_records.pending_search_index_record_ids("delete"),
      )
    end

    # A signed-in follow keeps follower_user_id and the address of that moment, which an email change
    # never rewrites. Matched on that link only: an old address alone is no proof its rows are theirs.
    def anonymize_linked_followers!(anonymized_email)
      linked = Follower.where(follower_user_id: @user.id).where.not(email: anonymized_email)
                       .pluck(:id, :followed_id, :deleted_at)
      return if linked.empty?

      # (email, followed_id) is unique, so at most one row per followed seller can take the address.
      taken_followed_ids = Follower.where(email: anonymized_email, followed_id: linked.map(&:second).uniq).pluck(:followed_id)
      kept_ids = linked.reject { taken_followed_ids.include?(_2) }
                       .group_by(&:second)
                       .map { |_, rows| rows.min_by { |id, _, deleted_at| [deleted_at ? 1 : 0, id] }.first }
      Follower.where(id: linked.map(&:first) - kept_ids).delete_all
      @counts[:followers] += Follower.where(id: kept_ids).update_all(email: anonymized_email)
    end

    # Written in the erasure's transaction so the ids commit exactly when the rows do. After that
    # commit nothing can find these documents again: the rows no longer hold the address, and the
    # conflicting members are gone. Locked and unioned so a concurrent run cannot drop ids.
    def record_pending_audience_search_index!(reindex_ids:, unindex_ids:)
      return if reindex_ids.empty? && unindex_ids.empty?

      @user.reload.with_lock do
        @user.gdpr_audience_reindex_member_ids = @user.gdpr_audience_reindex_member_ids | reindex_ids
        @user.gdpr_audience_unindex_member_ids = @user.gdpr_audience_unindex_member_ids | unindex_ids
        @user.save!(validate: false)
      end
    end

    # Inline, not queued: reliable_push! can hold a job in console memory without raising, so the ids
    # are cleared only after every write completes and are kept on failure. Rescued so the guardian
    # deletion that follows still runs.
    def write_pending_audience_search_documents!
      reindex_ids = unindex_ids = []
      # A lagging replica would hand back the pre-erasure row, and its body would put the address
      # back in the index.
      ApplicationRecord.connected_to(role: :writing) do
        @user.reload
        reindex_ids = @user.gdpr_audience_reindex_member_ids
        unindex_ids = @user.gdpr_audience_unindex_member_ids
        return if reindex_ids.empty? && unindex_ids.empty?

        members = AudienceMember.where(id: reindex_ids).to_a
        # A member deleted since has no row to index, so its document is removed instead.
        unindex_ids |= reindex_ids - members.map(&:id)
        indexer = ElasticsearchIndexerWorker.new
        members.each do |member|
          indexer.perform("index", { "record_id" => member.id, "class_name" => "AudienceMember", "body" => member.as_indexed_json })
        end
        unindex_ids.each do |member_id|
          indexer.perform("delete", { "record_id" => member_id, "class_name" => "AudienceMember" })
        end

        @user.reload.with_lock do
          @user.gdpr_audience_reindex_member_ids = (@user.gdpr_audience_reindex_member_ids - reindex_ids).presence
          @user.gdpr_audience_unindex_member_ids = (@user.gdpr_audience_unindex_member_ids - unindex_ids).presence
          @user.save!(validate: false)
        end
      end
    rescue => e
      Rails.logger.error("GDPR: could not update audience search documents for user #{@user.id}: #{e.message}")
      ErrorNotifier.notify(e)
      @search_index_error = "Erasure incomplete: audience member search record(s) " \
                            "#{(reindex_ids | unindex_ids).join(', ')} could not be updated or removed in " \
                            "search and may still show the original address there. Run the erasure again to " \
                            "retry them before confirming the request as fulfilled."
      record_incomplete_search_index_note!
    end

    # Durable like the guardian note: the returned error is gone once the console session is.
    def record_incomplete_search_index_note!
      @user.add_payout_note(content: "GDPR: #{@search_index_error}", seller_visible: false)
    rescue => e
      Rails.logger.error("GDPR: failed to record incomplete-erasure note for user #{@user.id}: #{e.message}")
      ErrorNotifier.notify(e)
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
        payment_method_type: nil,
        stripe_account_id: nil,
        recurring_authorization_verified_at: nil,
        recurring_authorization_currency: nil,
        recurring_authorization_max_amount_cents: nil,
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
        carts_anonymized: @counts[:carts],
        sent_post_emails_deleted: @counts[:sent_post_emails],
        audience_members_anonymized: @counts[:audience_members],
        followers_anonymized: @counts[:followers],
        imported_customers_anonymized: @counts[:imported_customers],
        external_cleanup_needed: [
          "Helper/Supabase (customer conversations)",
          "Gmail (correspondence)",
          "Stripe (customer data)"
        ]
      }
    end
end
