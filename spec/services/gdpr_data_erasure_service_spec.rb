# frozen_string_literal: true

require "spec_helper"

describe GdprDataErasureService do
  let(:user) { create(:user, email: "john@example.com", name: "John Doe", bio: "My bio", street_address: "123 Main St", city: "New York", state: "NY", zip_code: "10001", country: "US") }
  let(:admin) { create(:user, email: "admin@example.com", name: "Admin") }

  describe "#perform!" do
    with_versioning do
      [false, true].each do |already_deleted|
        it "audits staff cleanup before erasure with already_deleted=#{already_deleted}" do
          gumroad = create(:user, email: ApplicationMailer::ADMIN_EMAIL, is_team_member: true)
          staff = create(:user, is_team_member: true, announcement_notification_enabled: false)
          membership = create(:team_membership, seller: gumroad, user: staff)
          gumroad.update_column(:deleted_at, 1.day.ago) if already_deleted
          staff.update_column(:timezone, "invalid")
          old_flags = staff.flags
          allow_any_instance_of(User).to receive(:clear_products_cache).and_wrap_original do |original, *args|
            raise "member cache unavailable" if original.receiver.id == staff.id
            original.call(*args)
          end

          result = described_class.new(gumroad, performed_by: admin).perform!

          expect(result[:success]).to eq(true)
          expect(gumroad.reload).not_to be_is_team_member
          expect(gumroad.email).to eq("deleted-#{gumroad.id}@deleted.gumroad.com")
          expect(staff.reload).not_to be_is_team_member
          expect(staff.announcement_notification_enabled).to eq(false)
          expect(staff.versions.last.changeset["flags"]).to eq([old_flags, staff.flags])
          expect(gumroad.versions.where(event: "update").filter_map { _1.changeset["flags"] }.last).to eq([gumroad.flags | User.flag_mapping["flags"][:is_team_member], gumroad.flags])
          expect(membership.reload).not_to be_deleted
        end
      end
    end

    it "anonymizes user PII" do
      result = described_class.new(user, performed_by: admin).perform!

      expect(result[:success]).to eq(true)
      user.reload
      expect(user.name).to eq("[deleted]")
      expect(user.email).to eq("deleted-#{user.id}@deleted.gumroad.com")
      expect(user.bio).to be_nil
      expect(user.street_address).to be_nil
      expect(user.city).to be_nil
      expect(user.state).to be_nil
      expect(user.zip_code).to be_nil
      expect(user.country).to be_nil
      expect(user.current_sign_in_ip).to be_nil
      expect(user.last_sign_in_ip).to be_nil
      expect(user.account_created_ip).to be_nil
      expect(user.deleted_at).to be_present
    end

    it "closes a piracy report that never went out, and keeps the row" do
      report = create(:piracy_report, :awaiting_signature, seller: user)

      result = described_class.new(user, performed_by: admin).perform!

      expect(result[:success]).to eq(true)
      # `reload` raises if the row is gone: erasure closes the report, it does not delete it.
      expect(report.reload.state).to eq("cancelled")
    end

    [false, true].each do |already_deleted|
      it "revokes the OAuth access tokens of every application with already_deleted=#{already_deleted}" do
        access_token = create("doorkeeper/access_token", application: create(:oauth_application), resource_owner_id: user.id, scopes: "view_sales")
        user.update_column(:deleted_at, 1.day.ago) if already_deleted

        described_class.new(user, performed_by: admin).perform!

        expect(access_token.reload).to be_revoked
      end
    end

    context "when the erased account is on the Gumroad team" do
      it "clears the staff flag of the account and of the members it grants the flag to" do
        gumroad_account = create(:admin_user, email: ApplicationMailer::ADMIN_EMAIL)
        staff_user = create(:admin_user)
        create(:team_membership, user: staff_user, seller: gumroad_account)

        described_class.new(gumroad_account, performed_by: admin).perform!

        expect(gumroad_account.reload).not_to be_is_team_member
        expect(staff_user.reload).not_to be_is_team_member
      end

      it "clears the flag of an account closed before this cleanup existed" do
        staff_user = create(:admin_user)
        staff_user.update!(deleted_at: Time.current)

        described_class.new(staff_user, performed_by: admin).perform!

        expect(staff_user.reload).not_to be_is_team_member
      end
    end

    it "nulls PII columns on all compliance info rows, including previously replaced ones" do
      # Compliance edits replace the row (Immutable), so a user accumulates soft-deleted
      # rows that still carry PII — erasure must scrub those too, not just the alive one.
      replaced_info = create(:user_compliance_info, user:, full_name: "John Doe", telephone_number: "+1 555 555 0100")
      replaced_info.mark_deleted!
      current_info = create(:user_compliance_info, user:, full_name: "John Doe", telephone_number: "+1 555 555 0100")

      described_class.new(user, performed_by: admin).perform!

      [replaced_info, current_info].each do |compliance_info|
        compliance_info.reload
        expect(compliance_info.deleted_at).to be_present
        expect(compliance_info.full_name).to be_nil
        expect(compliance_info.first_name).to be_nil
        expect(compliance_info.last_name).to be_nil
        expect(compliance_info.birthday).to be_nil
        expect(compliance_info.street_address).to be_nil
        expect(compliance_info.city).to be_nil
        expect(compliance_info.state).to be_nil
        expect(compliance_info.zip_code).to be_nil
        expect(compliance_info.telephone_number).to be_nil
        expect(compliance_info.phone).to be_nil
        # The JsonData concern deserializes a NULL column as an empty hash.
        expect(compliance_info.json_data).to be_blank
        # Country stays with the retained transaction/tax records (Article 17(3)(b)).
        expect(compliance_info.country).to eq("United States")
      end
    end

    it "clears the legal guardian's own details, since an adult's PII would otherwise survive on a separate row" do
      guardian = create(:guardian, user:, first_name: "Ellie", last_name: "Doe", email: "ellie@example.com")
      replaced_info = create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
      replaced_info.mark_deleted!

      described_class.new(user, performed_by: admin).perform!

      expect(guardian.reload).to have_attributes(
        first_name: nil,
        last_name: nil,
        email: nil,
        phone: nil,
        date_of_birth: nil,
        street_address: nil
      )
      expect(guardian.has_individual_tax_id?).to be(false)
      # The row and the reference survive so the compliance history is still readable.
      expect(replaced_info.reload.guardian_id).to eq(guardian.id)
    end

    it "leaves other sellers' guardians alone" do
      other_seller = create(:user)
      other_guardian = create(:guardian, user: other_seller, first_name: "Someone")
      create(:user_compliance_info, user: other_seller, birthday: 15.years.ago.to_date, guardian: other_guardian)
      create(:user_compliance_info, user:)

      described_class.new(user, performed_by: admin).perform!

      expect(other_guardian.reload.first_name).to eq("Someone")
    end

    describe "the guardian's copy held by our payment processor" do
      let!(:merchant_account) do
        create(:merchant_account, user:, charge_processor_merchant_id: "acct_erasure_test")
      end

      before do
        allow(Stripe::Account).to receive(:delete_person)
        # Spied rather than left real: these examples assert on whether a retained vendor copy was
        # reported, which is the only signal that Stripe still holds the adult's details.
        allow(ErrorNotifier).to receive(:notify)
        allow(Stripe::Account).to receive(:list_persons)
          .and_return(Stripe::ListObject.construct_from(data: []))
      end

      # Anonymizing our row does not reach Stripe, so without this the adult's name, date of birth
      # and address survive the erasure request at our processor.
      it "deletes the guardian's person from Stripe" do
        guardian = create(:guardian, user:, stripe_person_id: "person_erase_me")
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)

        described_class.new(user, performed_by: admin).perform!

        expect(Stripe::Account).to have_received(:delete_person).with("acct_erasure_test", "person_erase_me")
      end

      it "still deletes the guardian's person when a rerun cannot read the pending sent post email recheck" do
        guardian = create(:guardian, user:, stripe_person_id: "person_erase_me")
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
        user.update_columns(email: "deleted-#{user.id}@deleted.gumroad.com")
        user.gdpr_sent_post_emails_recheck_pending = "earlier-run-generation"
        user.save!(validate: false)
        allow_any_instance_of(User).to receive(:gdpr_sent_post_emails_recheck_pending)
          .and_raise(ActiveRecord::ConnectionNotEstablished, "primary unavailable")

        result = described_class.new(User.find(user.id), performed_by: admin).perform!

        expect(result[:success]).to eq(false)
        expect(result[:error]).to include("could not check whether an earlier run finished rechecking sent post email records")
        expect(Stripe::Account).to have_received(:delete_person).with("acct_erasure_test", "person_erase_me")
      end

      it "keeps the recheck pending and still deletes the guardian's person when the marker cannot be cleared" do
        guardian = create(:guardian, user:, stripe_person_id: "person_erase_me")
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
        create(:sent_post_email, email: user.email)
        # The clear is the only row lock taken on an account that already holds a marker.
        allow_any_instance_of(User).to receive(:with_lock).and_wrap_original do |original, *args, &block|
          raise ActiveRecord::LockWaitTimeout, "Lock wait timeout exceeded" if original.receiver.gdpr_sent_post_emails_recheck_pending.present?
          original.call(*args, &block)
        end

        result = described_class.new(user, performed_by: admin).perform!

        expect(result[:success]).to eq(false)
        expect(result[:error]).to include("were rechecked after the erasure, but its pending recheck marker could not be cleared")
        expect(result[:error]).to include("Once no other erasure of this account is running")
        expect(user.reload.gdpr_sent_post_emails_recheck_pending).to be_present
        expect(SentPostEmail.where(email: "john@example.com")).to be_empty
        expect(Stripe::Account).to have_received(:delete_person).with("acct_erasure_test", "person_erase_me")
        expect(user.comments.where(comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE).last.content)
          .to include("its pending recheck marker could not be cleared")
        expect(described_class.new(User.find(user.id), performed_by: admin).perform!).to include(success: false)
      end

      # The gap a recorded id alone cannot close: a sync that created the Person but failed before
      # saving its id leaves no local pointer, and erasure cannot wait for a next sync to supply one.
      it "deletes a guardian person Stripe holds that we never recorded an id for" do
        guardian = create(:guardian, user:, stripe_person_id: nil)
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
        allow(Stripe::Account).to receive(:list_persons)
          .and_return(Stripe::ListObject.construct_from(data: [{ id: "person_orphaned" }]))

        described_class.new(user, performed_by: admin).perform!

        expect(Stripe::Account).to have_received(:delete_person).with("acct_erasure_test", "person_orphaned")
      end

      it "does not call Stripe for a guardian Stripe holds no person for" do
        guardian = create(:guardian, user:)
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)

        described_class.new(user, performed_by: admin).perform!

        expect(Stripe::Account).not_to have_received(:delete_person)
      end

      # A scan Stripe will not answer must not abandon the erasure: the recorded ids still go. But it
      # is the least complete scan there is, so it cannot report the account cleared either.
      it "deletes the recorded person even when the scan fails, and reports the erasure incomplete" do
        guardian = create(:guardian, user:, stripe_person_id: "person_recorded")
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
        allow(Stripe::Account).to receive(:list_persons)
          .and_raise(Stripe::APIError.new("Stripe is down"))

        result = described_class.new(user, performed_by: admin).perform!

        expect(Stripe::Account).to have_received(:delete_person).with("acct_erasure_test", "person_recorded")
        expect(result[:success]).to be(false)
        expect(result[:error]).to include("could not be fully scanned")
      end

      # The local row must still be anonymized: a processor-side failure cannot be a reason to leave
      # the seller's own data in place. But the erasure itself is NOT complete — a third party's
      # identity data is still at Stripe — so it must not report success.
      it "still anonymizes the local row when the Stripe deletion fails" do
        guardian = create(:guardian, user:, stripe_person_id: "person_locked", first_name: "Ellie")
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
        allow(Stripe::Account).to receive(:delete_person)
          .and_raise(Stripe::InvalidRequestError.new("Cannot delete", nil))

        result = described_class.new(user, performed_by: admin).perform!

        expect(guardian.reload.first_name).to be_nil
        expect(result[:success]).to be(false)
        expect(result[:error]).to include("Erasure incomplete")
        # The notification is the only signal that Stripe kept its copy, so it is asserted rather
        # than assumed — without it the retained copy is invisible.
        expect(ErrorNotifier).to have_received(:notify)
      end

      # Reporting the failure is not enough on its own: erasure has no second pass, so without a
      # queued retry a transient Stripe outage retains the adult's details permanently.
      it "queues a retry for a guardian person Stripe refused to delete" do
        guardian = create(:guardian, user:, stripe_person_id: "person_locked")
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
        allow(Stripe::Account).to receive(:delete_person)
          .and_raise(Stripe::InvalidRequestError.new("Cannot delete", nil))

        described_class.new(user, performed_by: admin).perform!

        expect(DeleteGuardianStripePersonJob).to have_enqueued_sidekiq_job(
          "person_locked", "acct_erasure_test", user.id
        )
      end

      it "does not queue a retry when the deletion succeeds" do
        guardian = create(:guardian, user:, stripe_person_id: "person_erase_me")
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)

        result = described_class.new(user, performed_by: admin).perform!

        expect(result[:success]).to be(true)
        expect(DeleteGuardianStripePersonJob.jobs).to be_empty
      end

      # Switching payout method, changing country, or connecting Stripe Connect all mark the Stripe
      # account dead LOCALLY without deleting it at Stripe, so the guardian's Person keeps holding
      # an adult's name, date of birth and address there. Resolving only the live account would skip
      # it and still report success.
      it "deletes the person from a Stripe account that was only deleted on our side" do
        guardian = create(:guardian, user:, stripe_person_id: "person_erase_me")
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
        merchant_account.delete_charge_processor_account!
        expect(user.reload.stripe_account).to be_nil

        described_class.new(user, performed_by: admin).perform!

        expect(Stripe::Account).to have_received(:delete_person).with("acct_erasure_test", "person_erase_me")
      end

      # "No such account" is not evidence the Person was deleted, and when it is the ONLY account
      # tried nothing has confirmed the delete — so the erasure cannot report itself complete. This
      it "does not report success when the only Stripe account tried cannot confirm the delete" do
        guardian = create(:guardian, user:, stripe_person_id: "person_erase_me", first_name: "Ellie")
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
        allow(Stripe::Account).to receive(:delete_person)
          .and_raise(Stripe::InvalidRequestError.new("No such account: 'acct_erasure_test'", nil, code: "resource_missing"))

        result = described_class.new(user, performed_by: admin).perform!

        expect(result[:success]).to be(false)
        expect(result[:error]).to include("Erasure incomplete")
        expect(DeleteGuardianStripePersonJob).to have_enqueued_sidekiq_job("person_erase_me", "acct_erasure_test", user.id)
        # Our own copy still goes: a processor-side failure is not a reason to keep the local row.
        expect(guardian.reload.first_name).to be_nil
      end

      # The reason a dead account is not itself a failure: erasure tries every account the seller
      # ever held, so a "no such account" alongside a real delete is expected. Only a Person that NO
      # account acknowledged is unverified, so this must not regress into failing every erasure for
      # a re-onboarded seller.
      it "reports success when another account confirmed the delete" do
        guardian = create(:guardian, user:, stripe_person_id: "person_erase_me")
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
        create(:merchant_account, user:, charge_processor_merchant_id: "acct_dead_one")
        allow(Stripe::Account).to receive(:delete_person)
          .with("acct_dead_one", "person_erase_me")
          .and_raise(Stripe::InvalidRequestError.new("No such account: 'acct_dead_one'", nil, code: "resource_missing"))

        result = described_class.new(user, performed_by: admin).perform!

        expect(result[:success]).to be(true)
        expect(DeleteGuardianStripePersonJob.jobs).to be_empty
      end

      # The one case where we know Stripe holds a copy and have no handle to reach it. Silence here
      # would mean telling the seller their data was erased while an adult's details stay with our
      # processor and nobody ever finds out.
      #
      # The account is killed first because charge_processor_merchant_id is validated as present
      # only while the account is alive — a blank id is reachable exactly on a dead row.
      it "reports when a synced guardian has no resolvable Stripe account to delete from" do
        guardian = create(:guardian, user:, stripe_person_id: "person_orphaned")
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
        merchant_account.delete_charge_processor_account!
        merchant_account.update!(charge_processor_merchant_id: nil)

        result = described_class.new(user, performed_by: admin).perform!

        # No deletion was attempted and none can be retried, so this must not read as fulfilled.
        expect(result[:success]).to be(false)
        expect(result[:error]).to include("Erasure incomplete")
        expect(result[:error]).to include("no resolvable Stripe account")
        expect(result[:error]).to include("manually")
        expect(Stripe::Account).not_to have_received(:delete_person)
        expect(ErrorNotifier).to have_received(:notify).with(/guardian Stripe person/)
      end

      # Sentry alerts age out; whoever re-checks the request months later needs the Person id from
      # the account itself, and the unreachable case has no retry job carrying it.
      it "records which unreachable person is still held at Stripe on the account" do
        guardian = create(:guardian, user:, stripe_person_id: "person_orphaned")
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
        merchant_account.delete_charge_processor_account!
        merchant_account.update!(charge_processor_merchant_id: nil)

        described_class.new(user, performed_by: admin).perform!

        note = user.reload.comments.where(comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE).last
        expect(note.content).to include("person_orphaned")
        expect(note.content).to include("still held at Stripe")
      end

      # The unreachable state is keyed on a RECORDED person id, not on having no account: a guardian
      # that was never synced has nothing at Stripe, so an account we cannot resolve is irrelevant
      # and the erasure is genuinely complete. Without this the fix above would fail every erasure
      # for a seller with a dead account and an unsynced guardian.
      it "still reports success when an unresolvable account has no synced guardian" do
        guardian = create(:guardian, user:, stripe_person_id: nil)
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
        merchant_account.delete_charge_processor_account!
        merchant_account.update!(charge_processor_merchant_id: nil)

        result = described_class.new(user, performed_by: admin).perform!

        expect(result[:success]).to be(true)
        expect(ErrorNotifier).not_to have_received(:notify)
      end

      # The unreachable check keys on a Stripe row we cannot resolve an id for, NOT on the resolved
      # set being empty. One good account alongside one unresolvable row produces a non-empty set,
      # and the Person recorded against the unresolvable row is then looked for on the good account,
      # where Stripe answers "no such person" — which delete_person_by_id reports as SUCCESS. Keying
      # on the empty set therefore let this erasure report itself fulfilled with an adult's name,
      # date of birth and tax id still standing on the account we could not reach.
      it "reports incomplete when one Stripe row is unresolvable and another account answers no such person" do
        guardian = create(:guardian, user:, stripe_person_id: "person_on_lost_account")
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
        lost_account = create(:merchant_account, user:, charge_processor_merchant_id: "acct_lost")
        lost_account.delete_charge_processor_account!
        lost_account.update!(charge_processor_merchant_id: nil)
        # The surviving account genuinely does not hold this Person.
        allow(Stripe::Account).to receive(:delete_person).and_raise(
          Stripe::InvalidRequestError.new("No such person: 'person_on_lost_account'", nil, code: "resource_missing")
        )

        result = described_class.new(user, performed_by: admin).perform!

        expect(result[:success]).to be(false)
        expect(result[:error]).to include("no resolvable Stripe account")
        note = user.reload.comments.where(comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE).last
        expect(note.content).to include("person_on_lost_account")
      end

      # The guardian surface must not run at all for a seller who never had a guardian. The union of
      # account resolutions used to run unconditionally, so every erasure on the platform took the
      # per-account guardian sync lock — and a Redis outage then failed those erasures with a note
      # telling a human to hand-scan Stripe for a guardian that never existed.
      describe "a seller with no guardian at all" do
        it "does not take the guardian sync lock" do
          allow(StripeGuardianManager).to receive(:with_account_sync_lock).and_call_original

          described_class.new(user, performed_by: admin).perform!

          expect(StripeGuardianManager).not_to have_received(:with_account_sync_lock)
        end

        it "still reports success when Redis is unreachable" do
          allow($redis).to receive(:set).and_raise(Redis::CannotConnectError, "no connection")

          result = described_class.new(user, performed_by: admin).perform!

          expect(result[:success]).to be(true)
          expect(user.reload.comments.where(comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE)).to be_empty
        end
      end

      # perform_async needs Redis, and a Redis outage is the headline case the remediation exists
      # for. Enqueueing before writing the note meant the first perform_async raised, jumped to the
      # method rescue, and the durable note — the human's only handle — was never written.
      it "writes the durable note even when the retry cannot be enqueued" do
        guardian = create(:guardian, user:, stripe_person_id: "person_erase_me")
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
        allow($redis).to receive(:set).and_raise(Redis::CannotConnectError, "no connection")
        allow(DeleteGuardianStripePersonJob).to receive(:perform_async)
          .and_raise(RedisClient::CannotConnectError, "no connection")

        result = described_class.new(user, performed_by: admin).perform!

        expect(result[:success]).to be(false)
        note = user.reload.comments.where(comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE).last
        expect(note).to be_present
        expect(note.content).to include("person_erase_me")
      end

      # A guardian sync that read the guardian before erasure anonymized it can still be mid-flight
      # when erasure reaches Stripe, and it creates its Person after any snapshot erasure took
      # earlier. So the two must be ordered against each other, or the newly created Person survives
      # an erasure that reported success — the adult's name, date of birth, address and tax id still
      # at our processor with the request marked fulfilled.
      describe "a guardian sync racing the erasure" do
        it "deletes a person that appeared at Stripe after the erasure started" do
          guardian = create(:guardian, user:, stripe_person_id: nil)
          create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
          # The racing sync's Person exists at Stripe only once erasure holds the lock. An erasure
          # that snapshotted the account's Persons before its transaction — as this one used to —
          # sees the empty account and deletes nothing.
          allow(Stripe::Account).to receive(:list_persons) do
            data = $redis.get("stripe_guardian_sync:acct_erasure_test") ? [{ id: "person_from_racing_sync" }] : []
            Stripe::ListObject.construct_from(data:)
          end

          described_class.new(user, performed_by: admin).perform!

          expect(Stripe::Account).to have_received(:delete_person)
            .with("acct_erasure_test", "person_from_racing_sync")
        end

        it "holds the guardian sync lock while it scans and deletes" do
          guardian = create(:guardian, user:, stripe_person_id: "person_erase_me")
          create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
          held = nil
          allow(Stripe::Account).to receive(:delete_person) do
            held = $redis.get("stripe_guardian_sync:acct_erasure_test")
          end

          described_class.new(user, performed_by: admin).perform!

          expect(held).to be_present
          expect($redis.get("stripe_guardian_sync:acct_erasure_test")).to be_nil
        end

        # Deleting without the lock would race the sync the lock exists to order, and skipping the
        # account silently would report a complete erasure. Neither: the delete is handed to the
        # retry job and the erasure fails until it confirms.
        it "reports the erasure incomplete and retries when the sync lock cannot be taken" do
          guardian = create(:guardian, user:, stripe_person_id: "person_erase_me")
          create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
          stub_const("StripeGuardianManager::SYNC_LOCK_WAIT_TIMEOUT", 0.seconds)
          $redis.set("stripe_guardian_sync:acct_erasure_test", "a-sync-is-running")

          result = described_class.new(user, performed_by: admin).perform!

          expect(result[:success]).to be(false)
          expect(result[:error]).to include("Erasure incomplete")
          expect(Stripe::Account).not_to have_received(:delete_person)
          expect(DeleteGuardianStripePersonJob).to have_enqueued_sidekiq_job(
            "person_erase_me", "acct_erasure_test", user.id
          )
          # The other holder's lock must survive, or both would run after all.
          expect($redis.get("stripe_guardian_sync:acct_erasure_test")).to eq("a-sync-is-running")
        end

        # The load-bearing half of the branch above. Handing the recorded ids to the retry job only
        # covers Persons we have a handle for — and the lock holder we lost to is a sync that may
        # have created a Person without yet writing its id, which is precisely the no-recorded-id
        # case. Keying the failure on "we found something to retry" reported success exactly when the
        # skipped scan was the only thing that could have found the Person.
        it "reports the erasure incomplete when the lock cannot be taken and no person id is recorded" do
          guardian = create(:guardian, user:, stripe_person_id: nil)
          create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
          stub_const("StripeGuardianManager::SYNC_LOCK_WAIT_TIMEOUT", 0.seconds)
          $redis.set("stripe_guardian_sync:acct_erasure_test", "a-sync-is-running")

          result = described_class.new(user, performed_by: admin).perform!

          expect(result[:success]).to be(false)
          expect(result[:error]).to include("could not be fully scanned")
          # Nothing to enqueue — a retry job takes a Person id — so the note naming the account is
          # the only handle a human gets.
          note = user.reload.comments.where(comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE).last
          expect(note.content).to include("acct_erasure_test")
        end

        # A merchant account created while the local transaction ran is absent from the pre-transaction
        # snapshot, and a sync can put a guardian Person on it. Erasure never locked or scanned that
        # account and reported success with the adult's details still at Stripe.
        it "deletes a guardian person on an account created after the snapshot" do
          guardian = create(:guardian, user:, stripe_person_id: nil)
          create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
          allow(Stripe::Account).to receive(:list_persons) do |stripe_account_id, _params|
            data = stripe_account_id == "acct_created_late" ? [{ id: "person_on_late_account" }] : []
            Stripe::ListObject.construct_from(data:)
          end
          # Created during the local transaction, after the snapshot was taken.
          allow_any_instance_of(described_class).to receive(:log_erasure!).and_wrap_original do |m, *args|
            create(:merchant_account, user:, charge_processor_merchant_id: "acct_created_late")
            m.call(*args)
          end

          described_class.new(user, performed_by: admin).perform!

          expect(Stripe::Account).to have_received(:delete_person)
            .with("acct_created_late", "person_on_late_account")
        end
      end

      # The scan is what erasure reports as the complete deletion set, so a Person past the first page
      # is not merely missed — it is an adult's identity data that erasure affirmatively reports gone.
      it "deletes guardian persons beyond the first page of Stripe's results" do
        guardian = create(:guardian, user:, stripe_person_id: nil)
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
        allow(Stripe::Account).to receive(:list_persons) do |_account_id, params|
          if params[:starting_after] == "person_page_one"
            Stripe::ListObject.construct_from(data: [{ id: "person_page_two" }], has_more: false)
          else
            Stripe::ListObject.construct_from(data: [{ id: "person_page_one" }], has_more: true)
          end
        end

        result = described_class.new(user, performed_by: admin).perform!

        expect(Stripe::Account).to have_received(:delete_person).with("acct_erasure_test", "person_page_one")
        expect(Stripe::Account).to have_received(:delete_person).with("acct_erasure_test", "person_page_two")
        # A scan that did reach the end is complete, so paginating must not make every erasure fail.
        expect(result[:success]).to be(true)
      end

      # A partial scan still found real Persons. Dropping them on the rescue would delete fewer than
      # the single-page version did — but deleting them is not clearing the account either.
      it "deletes the persons a partially failing scan did find and reports the erasure incomplete" do
        guardian = create(:guardian, user:, stripe_person_id: nil)
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
        allow(Stripe::Account).to receive(:list_persons) do |_account_id, params|
          raise Stripe::APIError.new("Stripe is down") if params[:starting_after]

          Stripe::ListObject.construct_from(data: [{ id: "person_page_one" }], has_more: true)
        end

        result = described_class.new(user, performed_by: admin).perform!

        expect(Stripe::Account).to have_received(:delete_person).with("acct_erasure_test", "person_page_one")
        # Every id the scan handed over deleted cleanly, so nothing is retained and nothing is being
        # retried. The unread pages are where an unrecorded Person hides, and only the scan could have
        # found it, so the account must be named for a human rather than passed off as erased.
        expect(result[:success]).to be(false)
        expect(result[:error]).to include("could not be fully scanned")
        note = user.reload.comments.where(comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE).last
        expect(note.content).to include("acct_erasure_test")
      end

      # Stripe says there is more but hands back no cursor to ask with. The loop has to stop, and the
      # unseen Persons are just as unseen as on a raised page.
      it "reports the erasure incomplete when Stripe offers no cursor for the next page" do
        guardian = create(:guardian, user:, stripe_person_id: nil)
        create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
        allow(Stripe::Account).to receive(:list_persons)
          .and_return(Stripe::ListObject.construct_from(data: [], has_more: true))

        result = described_class.new(user, performed_by: admin).perform!

        expect(result[:success]).to be(false)
        expect(result[:error]).to include("could not be fully scanned")
      end

      # A Redis outage is not a lock that is merely busy — the calls themselves raise. Those errors
      # used to escape as Redis errors rather than SyncLockUnavailable, so they missed the rescue
      # that remediates and landed in perform!'s generic one: the local copy anonymized, the
      # guardian's data still at Stripe, nothing retrying it and nothing recorded.
      describe "Redis being unreachable while locking" do
        it "reports the erasure incomplete and retries when the lock cannot be acquired" do
          guardian = create(:guardian, user:, stripe_person_id: "person_erase_me")
          create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
          allow($redis).to receive(:set).and_raise(Redis::CannotConnectError, "no connection")

          result = described_class.new(user, performed_by: admin).perform!

          expect(result[:success]).to be(false)
          expect(result[:error]).to include("Erasure incomplete")
          expect(DeleteGuardianStripePersonJob).to have_enqueued_sidekiq_job(
            "person_erase_me", "acct_erasure_test", user.id
          )
          note = user.reload.comments.where(comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE).last
          expect(note.content).to include("person_erase_me")
        end

        # RedisClient::Error is not a Redis::BaseError, so a rescue naming only the latter lets this
        # one through — the shape most likely to be missed.
        it "treats a RedisClient error the same as a Redis error" do
          guardian = create(:guardian, user:, stripe_person_id: "person_erase_me")
          create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
          allow($redis).to receive(:set).and_raise(RedisClient::ConnectionError, "closed")

          result = described_class.new(user, performed_by: admin).perform!

          expect(result[:success]).to be(false)
          expect(result[:error]).to include("Erasure incomplete")
          expect(DeleteGuardianStripePersonJob).to have_enqueued_sidekiq_job(
            "person_erase_me", "acct_erasure_test", user.id
          )
        end

        # Release runs after the deletes, so a failure there must not turn confirmed deletions into
        # a reported lock failure.
        it "still reports success when only the lock release fails" do
          guardian = create(:guardian, user:, stripe_person_id: "person_erase_me")
          create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
          allow($redis).to receive(:eval).and_raise(Redis::CannotConnectError, "no connection")

          result = described_class.new(user, performed_by: admin).perform!

          expect(result[:success]).to be(true)
          expect(Stripe::Account).to have_received(:delete_person)
            .with("acct_erasure_test", "person_erase_me")
          expect(DeleteGuardianStripePersonJob).not_to have_enqueued_sidekiq_job(
            "person_erase_me", "acct_erasure_test", user.id
          )
        end

        # The backstop for anything that escapes the per-person and per-account rescues entirely.
        # Without it, the anonymize has committed and the Person at Stripe has nothing behind it.
        it "retries and records when the deletion step raises outright" do
          guardian = create(:guardian, user:, stripe_person_id: "person_erase_me")
          create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
          allow(StripeGuardianManager).to receive(:stripe_person_ids_for_erasure)
            .and_raise(StandardError, "unexpected")

          result = described_class.new(user, performed_by: admin).perform!

          expect(result[:success]).to be(false)
          expect(DeleteGuardianStripePersonJob).to have_enqueued_sidekiq_job(
            "person_erase_me", "acct_erasure_test", user.id
          )
          note = user.reload.comments.where(comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE).last
          expect(note.content).to include("person_erase_me")
        end

        # The same backstop, for the guardian that has never been synced. There is no id to enqueue,
        # so the earlier shape returned a bare failure and recorded nothing — and this is precisely
        # the case where the scan that raised was the only thing that could have found a Person at
        # Stripe, since a Person created by a sync that died before writing its id has no local
        # handle at all.
        it "names the unscanned account when the deletion step raises with no recorded person id" do
          guardian = create(:guardian, user:, stripe_person_id: nil)
          create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
          allow(StripeGuardianManager).to receive(:stripe_person_ids_for_erasure)
            .and_raise(StandardError, "unexpected")

          result = described_class.new(user, performed_by: admin).perform!

          expect(result[:success]).to be(false)
          note = user.reload.comments.where(comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE).last
          expect(note.content).to include("acct_erasure_test")
          expect(note.content).to include("could not be fully scanned")
        end

        # An account whose scan completed is not unverified just because something later raised —
        # otherwise every such failure would tell a human to hand-scan an account we already listed,
        # and the note stops meaning anything.
        it "does not name an account whose scan completed before the failure" do
          guardian = create(:guardian, user:, stripe_person_id: "person_erase_me")
          create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
          allow_any_instance_of(described_class).to receive(:erasure_summary)
            .and_raise(StandardError, "after the scan")

          result = described_class.new(user, performed_by: admin).perform!

          expect(result[:success]).to be(false)
          note = user.reload.comments.where(comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE).last
          expect(note.content).to include("person_erase_me")
          expect(note.content).not_to include("could not be fully scanned")
        end

        # A failure before the anonymize erased nothing, so the Person at Stripe still belongs to a
        # live account that needs it. Deleting it would break the account's verification.
        it "does not touch the guardian person when the erasure failed before anonymizing" do
          guardian = create(:guardian, user:, stripe_person_id: "person_erase_me")
          create(:user_compliance_info, user:, birthday: 15.years.ago.to_date, guardian:)
          allow_any_instance_of(described_class).to receive(:anonymize_user_pii!)
            .and_raise(StandardError, "failed early")

          result = described_class.new(user, performed_by: admin).perform!

          expect(result[:success]).to be(false)
          expect(DeleteGuardianStripePersonJob.jobs).to be_empty
          expect(guardian.reload.stripe_person_id).to eq("person_erase_me")
        end
      end
    end

    it "anonymizes buyer purchases" do
      purchase = create(
        :free_purchase,
        purchaser: user,
        email: user.email,
        full_name: "John Doe",
        street_address: "123 Main St",
        ip_address: "127.0.0.1",
        browser_guid: "buyer-browser-guid",
      )

      described_class.new(user, performed_by: admin).perform!

      purchase.reload
      expect(purchase.email).to eq("deleted-#{user.id}@deleted.gumroad.com")
      expect(purchase.full_name).to eq("[deleted]")
      expect(purchase.street_address).to be_nil
      expect(purchase.ip_address).to be_nil
      expect(purchase.browser_guid).to be_nil
    end

    it "anonymizes guest purchases using the original email address" do
      purchase = create(
        :free_purchase,
        purchaser: nil,
        email: user.email,
        full_name: "John Doe",
        street_address: "123 Main St",
        ip_address: "127.0.0.1",
        browser_guid: "guest-browser-guid",
      )

      described_class.new(user, performed_by: admin).perform!

      purchase.reload
      expect(purchase.email).to eq("deleted-#{user.id}@deleted.gumroad.com")
      expect(purchase.full_name).to eq("[deleted]")
      expect(purchase.street_address).to be_nil
      expect(purchase.ip_address).to be_nil
      expect(purchase.browser_guid).to be_nil
    end

    it "destroys the user's social connect verifications without touching other users' rows" do
      user.update!(twitter_user_id: "12345", twitter_handle: "johndoe")
      create(:user_youtube_identity, user:, channel_id: "UC123", handle: "johndoe")
      create(:user_instagram_identity, user:, instagram_user_id: "17841400000000000", handle: "johndoe")
      create(:user_tiktok_identity, user:, tiktok_open_id: "open-123", handle: "johndoe")
      verification = create(:social_connect_verification, user:, platform: "twitter", uid: "12345", handle: "johndoe")
      other_verification = create(:social_connect_verification, platform: "twitter", uid: "12345", handle: "johndoe")

      described_class.new(user, performed_by: admin).perform!

      expect(SocialConnectVerification.exists?(id: verification.id)).to be(false)
      expect(SocialConnectVerification.where(user_id: user.id)).to be_empty
      expect(SocialConnectVerification.where(uid: "12345").pluck(:user_id)).to eq([other_verification.user_id])
      expect(user.reload.twitter_user_id).to be_nil
      expect(user.youtube_identity).to be_nil
      expect(user.instagram_identity).to be_nil
      expect(user.tiktok_identity).to be_nil
    end

    it "anonymizes all of the user's carts and credit card records" do
      historical_cart = create(:cart, user:, email: user.email, ip_address: "127.0.0.2", browser_guid: "historical-browser-guid")
      historical_cart.mark_deleted!
      alive_cart = create(:cart, user:, email: user.email, ip_address: "127.0.0.1", browser_guid: "browser-guid")
      credit_card = CreditCard.create!(
        visual: "UPI",
        card_type: CardType::UPI,
        stripe_customer_id: "cus_123",
        stripe_fingerprint: "fp_123",
        processor_payment_method_id: "pm_123",
        charge_processor_id: StripeChargeProcessor.charge_processor_id,
        payment_method_type: "upi",
        stripe_account_id: "acct_123",
        recurring_authorization_verified_at: Time.current,
        recurring_authorization_currency: Currency::INR,
        recurring_authorization_max_amount_cents: 100_000,
      )
      user.update!(credit_card:)

      described_class.new(user, performed_by: admin).perform!

      [alive_cart, historical_cart].each do |cart|
        expect(cart.reload.email).to eq("deleted-#{user.id}@deleted.gumroad.com")
        expect(cart.ip_address).to be_nil
        expect(cart.browser_guid).to be_nil
      end

      expect(credit_card.reload.card_type).to eq(GdprDataErasureService::ANONYMIZED_VALUE)
      expect(credit_card.visual).to eq(GdprDataErasureService::ANONYMIZED_VALUE)
      expect(credit_card.expiry_month).to be_nil
      expect(credit_card.expiry_year).to be_nil
      expect(credit_card.stripe_customer_id).to be_nil
      expect(credit_card.processor_payment_method_id).to be_nil
      expect(credit_card).not_to be_recurring_upi
      expect(credit_card.stripe_account_id).to be_nil
      expect(credit_card.recurring_authorization_verified_at).to be_nil
      expect(credit_card.recurring_authorization_currency).to be_nil
      expect(credit_card.recurring_authorization_max_amount_cents).to be_nil
    end

    it "anonymizes guest carts under the account's address or on a device only it used, and leaves shared devices alone" do
      create(:cart, user:, browser_guid: "own-device")
      own_device_guest_cart = create(:cart, :guest, email: nil, browser_guid: "own-device", ip_address: "10.0.0.1")
      address_guest_cart = create(:cart, :guest, email: "JOHN@example.com", browser_guid: "shared-device", ip_address: "10.0.0.2", deleted_at: 1.day.ago)
      other_account_cart = create(:cart, browser_guid: "shared-device")
      shared_device_guest_cart = create(:cart, :guest, email: nil, browser_guid: "shared-device", ip_address: "10.0.0.3")
      create(:free_purchase, purchaser: user, email: user.email, browser_guid: "family-device")
      relative_guest_cart = create(:cart, :guest, email: "relative@example.com", browser_guid: "family-device", deleted_at: 1.day.ago)
      family_device_guest_cart = create(:cart, :guest, email: nil, browser_guid: "family-device", ip_address: "10.0.0.4")

      result = described_class.new(user, performed_by: admin).perform!

      expect(address_guest_cart.reload).to have_attributes(email: "deleted-#{user.id}@deleted.gumroad.com", ip_address: nil, browser_guid: nil)
      expect(own_device_guest_cart.reload).to have_attributes(email: nil, ip_address: nil, browser_guid: nil)
      expect(shared_device_guest_cart.reload).to have_attributes(ip_address: "10.0.0.3", browser_guid: "shared-device")
      expect(family_device_guest_cart.reload).to have_attributes(ip_address: "10.0.0.4", browser_guid: "family-device")
      expect(relative_guest_cart.reload).to have_attributes(email: "relative@example.com", browser_guid: "family-device")
      expect(other_account_cart.reload.browser_guid).to eq("shared-device")
      expect(result[:summary][:carts_anonymized]).to eq(3)
    end

    it "deletes the address's sent post email rows on every seller's posts and keeps everyone else's" do
      first_post = create(:installment)
      second_post = create(:installment)
      create(:sent_post_email, post: first_post, email: user.email)
      create(:sent_post_email, post: second_post, email: user.email)
      other_recipient_row = create(:sent_post_email, post: first_post, email: "someone@example.com")

      result = described_class.new(user, performed_by: admin).perform!

      expect(SentPostEmail.where(email: "john@example.com")).to be_empty
      expect(SentPostEmail.pluck(:id)).to eq([other_recipient_row.id])
      expect(result[:summary][:sent_post_emails_deleted]).to eq(2)
    end

    it "deletes a sent post email row a send inserts after the first lookup, then clears the pending recheck" do
      post = create(:installment)
      lookups = 0
      pending_during_recheck = nil
      allow(SentPostEmail).to receive(:ids_for_email).and_wrap_original do |original, email|
        pending_during_recheck = User.find(user.id).gdpr_sent_post_emails_recheck_pending if lookups == 1
        original.call(email).tap do
          lookups += 1
          create(:sent_post_email, post:, email:) if lookups == 1
        end
      end

      result = described_class.new(user, performed_by: admin).perform!

      expect(result[:success]).to eq(true)
      expect(SentPostEmail.where(email: "john@example.com")).to be_empty
      expect(result[:summary][:sent_post_emails_deleted]).to eq(1)
      expect(pending_during_recheck).to be_present
      expect(user.reload.gdpr_sent_post_emails_recheck_pending).to be_nil
    end

    it "keeps the erasure incomplete across reruns until someone clears the pending sent post email recheck" do
      lookups = 0
      allow(SentPostEmail).to receive(:ids_for_email).and_wrap_original do |original, email|
        lookups += 1
        raise ActiveRecord::StatementTimeout, "timed out" if lookups == 2
        original.call(email)
      end
      notes = -> { user.comments.where(comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE).order(:id).pluck(:content) }

      result = described_class.new(user, performed_by: admin).perform!

      expect(result[:success]).to eq(false)
      expect(result[:error]).to include("sent post email records for the original address could not be rechecked")
      expect(user.reload.email).to eq("deleted-#{user.id}@deleted.gumroad.com")
      pending_generation = user.gdpr_sent_post_emails_recheck_pending
      expect(pending_generation).to be_present
      expect(notes.call.last).to include("sent post email records for the original address could not be rechecked")

      rerun = described_class.new(User.find(user.id), performed_by: admin).perform!

      expect(rerun[:success]).to eq(false)
      expect(rerun[:error]).to include("an earlier run did not finish rechecking sent post email records")
      expect(rerun[:error]).to include("Once no other erasure of this account is running, note the account's gdpr_sent_post_emails_recheck_pending value")
      expect(rerun[:error]).to include("clear that field only if it still holds the value you noted")
      expect(notes.call.last).to include("an earlier run did not finish rechecking sent post email records")
      expect(user.reload.gdpr_sent_post_emails_recheck_pending).to eq(pending_generation)
      expect(lookups).to eq(2)

      user.gdpr_sent_post_emails_recheck_pending = nil
      user.save!(validate: false)

      expect(described_class.new(User.find(user.id), performed_by: admin).perform!).to include(success: true)
    end

    it "does not let a run's finished recheck clear the pending recheck of a run that committed after it" do
      allow(SentPostEmail).to receive(:ids_for_email).and_wrap_original do |original, email|
        if User.find(user.id).gdpr_sent_post_emails_recheck_pending.present?
          # Another run read the address before this one committed, then committed its own generation.
          later_run = User.find(user.id)
          later_run.gdpr_sent_post_emails_recheck_pending = "later-run-generation"
          later_run.save!(validate: false)
        end
        original.call(email)
      end

      result = described_class.new(user, performed_by: admin).perform!

      expect(result[:success]).to eq(false)
      expect(result[:error]).to include("a later run of this erasure has not finished rechecking sent post email records")
      expect(user.reload.gdpr_sent_post_emails_recheck_pending).to eq("later-run-generation")
      expect(described_class.new(User.find(user.id), performed_by: admin).perform!).to include(success: false)
    end

    it "leaves no pending sent post email recheck when the erasure rolls back" do
      create(:sent_post_email, email: user.email)
      allow_any_instance_of(described_class).to receive(:log_erasure!).and_raise(StandardError, "failed late")

      result = described_class.new(user, performed_by: admin).perform!

      expect(result).to include(success: false, error: "failed late")
      expect(user.reload.email).to eq("john@example.com")
      expect(user.gdpr_sent_post_emails_recheck_pending).to be_nil
      expect(SentPostEmail.where(email: "john@example.com").count).to eq(1)
    end

    it "anonymizes the address on other sellers' audience, follower and imported customer rows and in their search documents" do
      seller = create(:user)
      follower = create(:active_follower, user: seller, email: user.email)
      imported_customer = create(:imported_customer, email: user.email)
      other_follower = create(:active_follower, user: seller, email: "someone@example.com")
      anonymized_email = "deleted-#{user.id}@deleted.gumroad.com"
      conflicting_seller = create(:user)
      conflicting_member_id = create(:active_follower, user: conflicting_seller, email: user.email).then { AudienceMember.find_by!(seller: conflicting_seller, email: _1.email).id }
      create(:audience_member, seller: conflicting_seller, email: anonymized_email)
      member_id = AudienceMember.find_by!(seller:, email: user.email).id
      other_member_id = AudienceMember.find_by!(seller:, email: "someone@example.com").id
      recreate_model_index(AudienceMember)
      index_model_records(AudienceMember)
      indexed_email = ->(id) { EsClient.get(index: AudienceMember.index_name, id:, ignore: 404)["_source"]&.fetch("email") }
      expect([member_id, conflicting_member_id, other_member_id].map(&indexed_email)).to eq(["john@example.com", "john@example.com", "someone@example.com"])
      ElasticsearchIndexerWorker.jobs.clear

      result = described_class.new(user, performed_by: admin).perform!

      expect(indexed_email.(member_id)).to eq(anonymized_email)
      expect(EsClient.exists?(index: AudienceMember.index_name, id: conflicting_member_id)).to be(false)
      expect(indexed_email.(other_member_id)).to eq("someone@example.com")
      expect(ElasticsearchIndexerWorker.jobs.select { _1["args"][1]["class_name"] == "AudienceMember" }).to be_empty
      expect(user.reload).to have_attributes(gdpr_audience_reindex_member_ids: [], gdpr_audience_unindex_member_ids: [])
      expect(follower.reload.email).to eq(anonymized_email)
      expect(imported_customer.reload.email).to eq(anonymized_email)
      expect(AudienceMember.find_by(seller:, email: anonymized_email)).to have_attributes(follower: false, details: nil)
      expect(AudienceMember.where(email: "john@example.com")).to be_empty
      expect(other_follower.reload.email).to eq("someone@example.com")
      expect(AudienceMember.find_by(seller:, email: "someone@example.com")).to be_follower
      expect(result[:summary]).to include(audience_members_anonymized: 1, followers_anonymized: 2, imported_customers_anonymized: 1)
    end

    it "removes the Google and Apple sign-in ids, leaving other accounts' sign-ins alone" do
      user.update!(google_uid: "google-subject-1")
      create(:user, google_uid: "google-subject-2")
      create(:user_external_authentication, user:, provider: "apple", uid: "apple-subject-1")
      other_apple_sign_in = create(:user_external_authentication, user: create(:user), provider: "apple", uid: "apple-subject-2")

      described_class.new(user, performed_by: admin).perform!

      expect(user.reload.google_uid).to be_nil
      expect(User.where.not(google_uid: nil).pluck(:google_uid)).to eq(["google-subject-2"])
      expect(UserExternalAuthentication.pluck(:id)).to eq([other_apple_sign_in.id])
    end

    it "keeps the rows a previous run anonymized when the erasure is run again" do
      follower = create(:active_follower, email: user.email)
      create(:sent_post_email, email: user.email)
      guest_cart = create(:cart, :guest, email: user.email)
      described_class.new(user, performed_by: admin).perform!

      anonymized_email = "deleted-#{user.id}@deleted.gumroad.com"

      result = described_class.new(user.reload, performed_by: admin).perform!

      expect(result[:success]).to eq(true)
      expect(Follower.where(id: follower.id).pluck(:email)).to eq([anonymized_email])
      expect(AudienceMember.where(email: anonymized_email).count).to eq(1)
      expect(guest_cart.reload.email).to eq(anonymized_email)
      expect(result[:summary]).to include(carts_anonymized: 0, sent_post_emails_deleted: 0, audience_members_anonymized: 0, followers_anonymized: 0)
    end

    it "anonymizes follows linked to the account under an earlier address, drops their audience follower details, and leaves other people's rows under it" do
      old_email = "john.old@example.com"
      anonymized_email = "deleted-#{user.id}@deleted.gumroad.com"
      seller, both_addresses_seller, two_old_addresses_seller, unrelated_seller = create_list(:user, 4)
      linked = create(:active_follower, user: seller, email: old_email, follower_user_id: user.id)
      shared_member = AudienceMember.find_by!(seller:, email: old_email)
      shared_member.details["purchases"] = [{ "id" => 1, "product_id" => 1, "price_cents" => 100, "created_at" => 7.days.ago.iso8601, "country" => "United States" }]
      shared_member.save!
      current = create(:active_follower, user: both_addresses_seller, email: user.email, follower_user_id: user.id)
      create(:active_follower, user: both_addresses_seller, email: old_email, follower_user_id: user.id)
      create(:deleted_follower, user: two_old_addresses_seller, email: "john.older@example.com", follower_user_id: user.id)
      alive_old = create(:active_follower, user: two_old_addresses_seller, email: old_email, follower_user_id: user.id)
      unlinked = create(:active_follower, user: unrelated_seller, email: old_email)
      other_account = create(:active_follower, user: create(:user), email: old_email, follower_user_id: create(:user).id)
      stranger = create(:active_follower, user: seller, email: "john.older@example.com")
      linked_member_ids = AudienceMember.where(seller: [both_addresses_seller, two_old_addresses_seller], email: old_email).ids
      unrelated_member_id = AudienceMember.find_by!(seller: unrelated_seller, email: old_email).id
      recreate_model_index(AudienceMember)
      index_model_records(AudienceMember)
      indexed = ->(id) { EsClient.get(index: AudienceMember.index_name, id:, ignore: 404)["_source"]&.slice("email", "follower", "customer") }
      expect(linked_member_ids.size).to eq(2)
      expect(indexed.(shared_member.id)).to eq("email" => old_email, "follower" => true, "customer" => true)

      result = described_class.new(user, performed_by: admin).perform!

      expect(result[:success]).to eq(true)
      expect(linked.reload.email).to eq(anonymized_email)
      expect(Follower.where(followed_id: both_addresses_seller.id).pluck(:id, :email)).to eq([[current.id, anonymized_email]])
      expect(Follower.where(followed_id: two_old_addresses_seller.id).pluck(:id, :email)).to eq([[alive_old.id, anonymized_email]])
      expect([unlinked, other_account, stranger].map { _1.reload.email }).to eq([old_email, old_email, "john.older@example.com"])
      expect(AudienceMember.find_by(seller:, email: "john.older@example.com")).to be_follower
      expect(AudienceMember.where(seller: [both_addresses_seller, two_old_addresses_seller], email: [old_email, "john.older@example.com"])).to be_empty
      expect(linked_member_ids.map { EsClient.exists?(index: AudienceMember.index_name, id: _1) }).to eq([false, false])
      expect(shared_member.reload).to have_attributes(follower: false, customer: true)
      expect(shared_member.details["purchases"].pluck("id")).to eq([1])
      expect(indexed.(shared_member.id)).to eq("email" => old_email, "follower" => false, "customer" => true)
      expect(AudienceMember.find(unrelated_member_id)).to be_follower
      expect(indexed.(unrelated_member_id)).to include("email" => old_email, "follower" => true)
      expect(result[:summary]).to include(followers_anonymized: 3)
    end

    it "anonymizes linked follows a previous run left under an earlier address when the erasure is run again" do
      seller, other_seller = create_list(:user, 2)
      anonymized_email = "deleted-#{user.id}@deleted.gumroad.com"
      erased = create(:active_follower, user: seller, email: user.email, follower_user_id: user.id)
      described_class.new(user, performed_by: admin).perform!
      create(:active_follower, user: seller, email: "john.old@example.com", follower_user_id: user.id)
      left_behind = create(:active_follower, user: other_seller, email: "john.old@example.com", follower_user_id: user.id)

      rerun = described_class.new(user.reload, performed_by: admin).perform!
      again = described_class.new(user.reload, performed_by: admin).perform!

      expect([rerun[:success], again[:success]]).to eq([true, true])
      expect(Follower.where(followed_id: seller.id).pluck(:id, :email)).to eq([[erased.id, anonymized_email]])
      expect(left_behind.reload.email).to eq(anonymized_email)
      expect(AudienceMember.where(email: "john.old@example.com")).to be_empty
      expect([rerun, again].map { _1[:summary][:followers_anonymized] }).to eq([1, 0])
    end

    it "removes the account's own purchases from audience members under an earlier address and keeps other buyers' purchases there" do
      old_email = "john.old@example.com"
      anonymized_email = "deleted-#{user.id}@deleted.gumroad.com"
      shared_seller, solo_seller = create_list(:user, 2)
      own_shared = create(:free_purchase, link: create(:product, user: shared_seller), purchaser: user, email: old_email)
      other_account = create(:free_purchase, link: create(:product, user: shared_seller), purchaser: create(:user), email: old_email)
      guest = create(:free_purchase, link: create(:product, user: shared_seller), purchaser: nil, email: old_email)
      own_solo = create(:free_purchase, link: create(:product, user: solo_seller), purchaser: user, email: old_email)
      shared_member = AudienceMember.find_by!(seller: shared_seller, email: old_email)
      solo_member_id = AudienceMember.find_by!(seller: solo_seller, email: old_email).id
      expect(shared_member.details["purchases"].pluck("id")).to contain_exactly(own_shared.id, other_account.id, guest.id)
      recreate_model_index(AudienceMember)
      index_model_records(AudienceMember)
      indexed_purchase_ids = ->(id) { EsClient.get(index: AudienceMember.index_name, id:, ignore: 404)["_source"]&.fetch("purchases")&.pluck("id") }

      result = described_class.new(user, performed_by: admin).perform!

      expect(result[:success]).to eq(true)
      expect(shared_member.reload.details["purchases"].pluck("id")).to contain_exactly(other_account.id, guest.id)
      expect(shared_member).to have_attributes(email: old_email, customer: true)
      expect(indexed_purchase_ids.(shared_member.id)).to contain_exactly(other_account.id, guest.id)
      expect(AudienceMember.exists?(solo_member_id)).to be(false)
      expect(EsClient.exists?(index: AudienceMember.index_name, id: solo_member_id)).to be(false)
      expect([own_shared, own_solo].map { _1.reload.email }).to eq([anonymized_email, anonymized_email])
      expect([other_account, guest].map { _1.reload.email }).to eq([old_email, old_email])
    end

    it "erases an account whose linked follow an earlier erasure of its old address already anonymized" do
      seller = create(:user)
      follower = create(:active_follower, user: seller, email: "john.old@example.com", follower_user_id: user.id)
      earlier_erasure = GdprAudienceRecordsAnonymizer.new(email: "john.old@example.com", anonymized_email: "buyer-1@deleted.gumroad.com")
      earlier_erasure.anonymize_audience_members!
      earlier_erasure.anonymize_followers!

      result = described_class.new(user, performed_by: admin).perform!

      expect(result[:success]).to eq(true)
      expect(follower.reload.email).to eq("deleted-#{user.id}@deleted.gumroad.com")
      expect(AudienceMember.find_by!(seller:, email: "buyer-1@deleted.gumroad.com")).to have_attributes(details: nil, follower: false)
    end

    it "keeps a purchase added to a linked follow's audience member after the erasure first read it" do
      seller = create(:user)
      create(:active_follower, user: seller, email: "john.old@example.com", follower_user_id: user.id)
      member = AudienceMember.find_by!(seller:, email: "john.old@example.com")
      purchase = { "id" => 1, "product_id" => 1, "price_cents" => 100, "created_at" => 7.days.ago.iso8601, "country" => "United States" }
      allow(AudienceMember).to receive(:lock).and_wrap_original do |original, *args|
        AudienceMember.find(member.id).then { _1.update_columns(details: _1.details.merge("purchases" => [purchase])) }
        original.call(*args)
      end

      expect(described_class.new(user, performed_by: admin).perform![:success]).to eq(true)

      expect(member.reload).to have_attributes(follower: false, customer: true)
      expect(member.details.keys).to eq(["purchases"])
    end

    it "rolls back the residual cleanup with the rest of the erasure when a step fails" do
      guest_cart = create(:cart, :guest, email: user.email)
      sent_post_email = create(:sent_post_email, email: user.email)
      follower = create(:active_follower, email: user.email)
      create(:audience_member, seller: follower.user, email: "deleted-#{user.id}@deleted.gumroad.com")
      allow_any_instance_of(GdprAudienceRecordsAnonymizer).to receive(:anonymize_imported_customers!).and_raise(StandardError, "boom")
      allow(EsClient).to receive(:index).and_call_original
      allow(EsClient).to receive(:delete).and_call_original
      ElasticsearchIndexerWorker.jobs.clear

      result = described_class.new(user, performed_by: admin).perform!

      expect(result).to eq(success: false, error: "boom")
      expect(user.reload.email).to eq("john@example.com")
      expect(guest_cart.reload.email).to eq("john@example.com")
      expect(SentPostEmail.exists?(sent_post_email.id)).to eq(true)
      expect(AudienceMember.where(email: "john@example.com").count).to eq(1)
      expect(EsClient).not_to have_received(:index)
      expect(EsClient).not_to have_received(:delete)
      expect(ElasticsearchIndexerWorker.jobs.select { _1["args"][1]["class_name"] == "AudienceMember" }).to be_empty
    end

    it "finishes the erasure when the same service is retried after a late failure" do
      guest_cart = create(:cart, :guest, email: user.email)
      create(:sent_post_email, email: user.email)
      follower = create(:active_follower, email: user.email)
      create(:product, user:)
      service = described_class.new(user, performed_by: admin)
      log_attempts = 0
      allow(service).to receive(:log_erasure!).and_wrap_original do |original|
        log_attempts += 1
        raise "transient failure" if log_attempts == 1
        original.call
      end
      allow(EsClient).to receive(:index).and_call_original
      expect(service.perform![:success]).to eq(false)
      expect(EsClient).not_to have_received(:index)

      result = service.perform!

      anonymized_email = "deleted-#{user.id}@deleted.gumroad.com"
      expect(result[:success]).to eq(true)
      expect(User.find(user.id)).to have_attributes(email: anonymized_email, deleted?: true)
      expect(guest_cart.reload.email).to eq(anonymized_email)
      expect(SentPostEmail.where(email: "john@example.com")).to be_empty
      expect(follower.reload.email).to eq(anonymized_email)
      expect(EsClient).to have_received(:index).with(hash_including(id: AudienceMember.find_by!(email: anonymized_email).id))
      expect(result[:summary]).to include(products_deleted: 1, carts_anonymized: 1, sent_post_emails_deleted: 1, audience_members_anonymized: 1, followers_anonymized: 1)
    end

    it "keeps the members whose search documents it could not write on the account until a rerun writes them" do
      user.update!(gumroad_day_timezone: "Pacific Time (US & Canada)")
      anonymized_email = "deleted-#{user.id}@deleted.gumroad.com"
      seller = create(:user)
      member_id = create(:active_follower, user: seller, email: user.email).then { AudienceMember.find_by!(seller:, email: _1.email).id }
      departed_seller = create(:user)
      departed_member_id = create(:active_follower, user: departed_seller, email: user.email).then { AudienceMember.find_by!(seller: departed_seller, email: _1.email).id }
      conflicting_seller = create(:user)
      conflicting_member_id = create(:active_follower, user: conflicting_seller, email: user.email).then { AudienceMember.find_by!(seller: conflicting_seller, email: _1.email).id }
      create(:audience_member, seller: conflicting_seller, email: anonymized_email)
      recreate_model_index(AudienceMember)
      index_model_records(AudienceMember)
      elasticsearch_down_for = [:index, :delete]
      [:index, :delete].each do |operation|
        allow(EsClient).to receive(operation).and_wrap_original do |original, *args|
          raise Faraday::ConnectionFailed, "elasticsearch down" if operation.in?(elasticsearch_down_for) && args.first[:index] == AudienceMember.index_name
          original.call(*args)
        end
      end
      allow(ErrorNotifier).to receive(:notify)
      indexed_email = ->(id) { EsClient.get(index: AudienceMember.index_name, id:, ignore: 404)["_source"]&.fetch("email") }
      payout_notes = -> { user.reload.comments.where(comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE).pluck(:content) }

      first = described_class.new(user, performed_by: admin).perform!

      expect(first[:success]).to eq(false)
      expect(first[:error]).to include(member_id.to_s, departed_member_id.to_s, conflicting_member_id.to_s)
      expect(payout_notes.call).to contain_exactly(a_string_including("GDPR: Erasure incomplete", conflicting_member_id.to_s))
      expect([member_id, conflicting_member_id].map(&indexed_email)).to eq(["john@example.com", "john@example.com"])
      expect(user.reload).to have_attributes(
        gdpr_audience_reindex_member_ids: contain_exactly(member_id, departed_member_id),
        gdpr_audience_unindex_member_ids: [conflicting_member_id],
      )

      elasticsearch_down_for = [:delete]
      still_down = described_class.new(User.find(user.id), performed_by: admin).perform!

      expect(still_down[:success]).to eq(false)
      expect(still_down[:error]).to include(member_id.to_s, conflicting_member_id.to_s)
      expect(payout_notes.call.size).to eq(2)
      expect(indexed_email.(member_id)).to eq(anonymized_email)
      expect(indexed_email.(conflicting_member_id)).to eq("john@example.com")
      expect(user.reload).to have_attributes(
        gdpr_audience_reindex_member_ids: contain_exactly(member_id, departed_member_id),
        gdpr_audience_unindex_member_ids: [conflicting_member_id],
      )

      elasticsearch_down_for = []
      AudienceMember.where(id: departed_member_id).delete_all
      restored = described_class.new(User.find(user.id), performed_by: admin).perform!

      expect(restored[:success]).to eq(true)
      expect(indexed_email.(member_id)).to eq(anonymized_email)
      expect([departed_member_id, conflicting_member_id].map { EsClient.exists?(index: AudienceMember.index_name, id: _1) }).to eq([false, false])
      expect(user.reload).to have_attributes(gdpr_audience_reindex_member_ids: [], gdpr_audience_unindex_member_ids: [], gumroad_day_timezone: "Pacific Time (US & Canada)")
    end

    it "keeps the member ids another run records while this one is writing them" do
      user.update!(gdpr_audience_unindex_member_ids: [999_001])
      create(:active_follower, email: user.email)
      recreate_model_index(AudienceMember)
      written_once = false
      allow(EsClient).to receive(:index).and_wrap_original do |original, *args|
        unless written_once
          written_once = true
          concurrent_run = User.find(user.id)
          concurrent_run.with_lock do
            concurrent_run.gdpr_audience_unindex_member_ids = concurrent_run.gdpr_audience_unindex_member_ids | [999_002]
            concurrent_run.save!(validate: false)
          end
        end
        original.call(*args)
      end
      allow(EsClient).to receive(:delete).and_call_original

      result = described_class.new(user, performed_by: admin).perform!

      member = AudienceMember.find_by!(email: "deleted-#{user.id}@deleted.gumroad.com")
      expect(result[:success]).to eq(true)
      expect(EsClient.get(index: AudienceMember.index_name, id: member.id)["_source"]["email"]).to eq(member.email)
      expect(EsClient).to have_received(:delete).with(hash_including(index: AudienceMember.index_name, id: 999_001))
      expect(user.reload).to have_attributes(gdpr_audience_reindex_member_ids: [], gdpr_audience_unindex_member_ids: [999_002])
    end

    it "writes nothing to the audience search index when a transaction around the erasure rolls back" do
      follower = create(:active_follower, email: user.email)
      conflicting_seller = create(:user)
      create(:active_follower, user: conflicting_seller, email: user.email)
      create(:audience_member, seller: conflicting_seller, email: "deleted-#{user.id}@deleted.gumroad.com")
      member_ids = AudienceMember.where(email: user.email).ids
      recreate_model_index(AudienceMember)
      index_model_records(AudienceMember)
      indexed_emails = -> { member_ids.map { EsClient.get(index: AudienceMember.index_name, id: _1, ignore: 404)["_source"]&.fetch("email") } }
      allow(EsClient).to receive(:index).and_call_original
      allow(EsClient).to receive(:delete).and_call_original

      ActiveRecord::Base.transaction do
        expect(described_class.new(user, performed_by: admin).perform![:success]).to eq(true)
        expect(indexed_emails.call).to eq(["john@example.com", "john@example.com"])
        raise ActiveRecord::Rollback
      end

      expect(EsClient).not_to have_received(:index)
      expect(EsClient).not_to have_received(:delete)
      expect(indexed_emails.call).to eq(["john@example.com", "john@example.com"])
      expect(User.find(user.id)).to have_attributes(email: "john@example.com", gdpr_audience_reindex_member_ids: [], gdpr_audience_unindex_member_ids: [])
      expect(follower.reload.email).to eq("john@example.com")
    end

    it "scrubs guest carts under the address and a former affiliate's sent post emails, and leaves carts on a device another account shares" do
      original_email = user.email
      user.update_columns(google_uid: "google-subject")
      guest_cart = create(:cart, :guest, email: original_email, ip_address: "127.0.0.3", browser_guid: "guest-guid")
      relative_cart = create(:cart, :guest, email: "relative@example.com", ip_address: "127.0.0.5", browser_guid: "own-guid", deleted_at: 1.day.ago)
      shared_device_cart = create(:cart, :guest, email: nil, ip_address: "127.0.0.4", browser_guid: "own-guid")
      other_cart = create(:cart, :guest, email: "other@example.com", browser_guid: "other-guid")
      create(:cart, user:, email: original_email, browser_guid: "own-guid")
      other_user_cart = create(:cart, user: create(:user), email: "shared@example.com", browser_guid: "own-guid")
      affiliate_seller = create(:user)
      create(:direct_affiliate, seller: affiliate_seller, affiliate_user: user, deleted_at: Time.current)
      affiliate_sent = create(:sent_post_email, post: create(:installment, seller: affiliate_seller), email: original_email)
      seller = create(:user)
      post = create(:installment, seller:)
      create(:purchase, link: create(:product, user: seller), email: original_email)
      sent = create(:sent_post_email, post:, email: original_email)
      other_sent = create(:sent_post_email, post:, email: "other@example.com")

      described_class.new(user, performed_by: admin).perform!

      expect(guest_cart.reload).to have_attributes(email: "deleted-#{user.id}@deleted.gumroad.com", ip_address: nil, browser_guid: nil)
      # own-guid is also on another account's cart, so it does not tie this address-less cart to the user.
      expect(shared_device_cart.reload).to have_attributes(ip_address: "127.0.0.4", browser_guid: "own-guid")
      expect(relative_cart.reload).to have_attributes(email: "relative@example.com", ip_address: "127.0.0.5", browser_guid: "own-guid")
      expect(other_cart.reload.email).to eq("other@example.com")
      expect(other_user_cart.reload).to have_attributes(email: "shared@example.com", browser_guid: "own-guid")
      expect(SentPostEmail.where(id: [affiliate_sent.id, sent.id])).to be_empty
      expect(SentPostEmail.exists?(other_sent.id)).to be(true)
      expect(user.reload.google_uid).to be_nil
    end

    it "deletes the user's device records" do
      ios_device = create(:device, user:, token: "ios-device-token")
      android_device = create(:android_device, user:, token: "android-device-token")
      other_user_device = create(:device, token: "other-user-device-token")

      described_class.new(user, performed_by: admin).perform!

      expect(Device.exists?(ios_device.id)).to eq(false)
      expect(Device.exists?(android_device.id)).to eq(false)
      expect(Device.exists?(other_user_device.id)).to eq(true)
    end

    it "invokes the private subscription cancellation helper during erasure" do
      expect(user).to receive(:cancel_active_subscriptions!)

      described_class.new(user, performed_by: admin).perform!
    end

    it "deactivates the account and deletes products" do
      product = create(:product, user: user)

      described_class.new(user, performed_by: admin).perform!

      user.reload
      expect(user.deleted?).to eq(true)
      expect(product.reload.deleted?).to eq(true)
    end

    it "erases an account holding a record that no longer validates" do
      # Erasure shares the closure's cleanup (User#soft_delete_owned_records!), which skips
      # validations: a legacy row that fails one must not abort a legally mandated erasure.
      installment = create(:installment, seller: user)
      installment.update_columns(message: "<p><br></p>", published_at: nil)
      expect(installment.reload).to be_invalid

      result = described_class.new(user, performed_by: admin).perform!

      expect(result[:success]).to eq(true)
      expect(user.reload.deleted?).to eq(true)
      expect(installment.reload.deleted?).to eq(true)
    end

    it "deletes the user's public media files and purges their blobs from public storage" do
      public_file = PublicFile.new(seller: user, resource: user, display_name: "Logo")
      public_file.file.attach(
        io: File.open(Rails.root.join("spec/support/fixtures/smilie.png")),
        filename: "smilie.png",
        content_type: "image/png",
      )
      public_file.save!

      # purge_later enqueues an ActiveStorage purge job that deletes the blob's stored bytes;
      # asserting on the call keeps the spec independent of the test queue adapter.
      expect_any_instance_of(ActiveStorage::Blob).to receive(:purge_later)

      described_class.new(user, performed_by: admin).perform!

      expect(public_file.reload).to be_deleted
    end

    it "still purges the remaining media files when deleting one of them fails" do
      first_file, second_file = 2.times.map do |i|
        public_file = PublicFile.new(seller: user, resource: user, display_name: "Logo #{i}")
        public_file.file.attach(
          io: File.open(Rails.root.join("spec/support/fixtures/smilie.png")),
          filename: "smilie-#{i}.png",
          content_type: "image/png",
        )
        public_file.save!
        public_file
      end

      # Simulate a transient failure on the first file: erasure should log it and keep going
      # instead of leaving the second file publicly accessible.
      allow_any_instance_of(PublicFile).to receive(:mark_deleted_and_purge_file!).and_wrap_original do |original, *args|
        raise "boom" if original.receiver.id == first_file.id
        original.call(*args)
      end

      described_class.new(user, performed_by: admin).perform!

      expect(first_file.reload).not_to be_deleted
      expect(second_file.reload).to be_deleted
    end

    it "reports only alive products in the erasure summary" do
      create(:product, user: user)
      deleted_product = create(:product, user: user)
      deleted_product.delete!

      result = described_class.new(user, performed_by: admin).perform!

      expect(result[:summary][:products_deleted]).to eq(1)
    end

    it "logs the erasure as a comment" do
      described_class.new(user, performed_by: admin).perform!

      comment = user.comments.last
      expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_NOTE)
      expect(comment.content).to include("GDPR data erasure performed")
      expect(comment.content).to include("Transaction records retained")
    end

    it "returns external cleanup instructions" do
      result = described_class.new(user, performed_by: admin).perform!

      expect(result[:summary][:external_cleanup_needed]).to include("Helper/Supabase (customer conversations)")
      expect(result[:summary][:external_cleanup_needed]).to include("Stripe (customer data)")
    end

    it "skips profile asset removal when transactional erasure work fails" do
      service = described_class.new(user, performed_by: admin)
      allow(service).to receive(:remove_profile_assets!)
      allow(service).to receive(:log_erasure!).and_raise(StandardError, "boom")

      result = service.perform!

      expect(result[:success]).to eq(false)
      expect(service).not_to have_received(:remove_profile_assets!)
    end
  end
end
