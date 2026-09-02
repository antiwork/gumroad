# frozen_string_literal: true

require "spec_helper"

describe GdprDataErasureService do
  let(:user) { create(:user, email: "john@example.com", name: "John Doe", bio: "My bio", street_address: "123 Main St", city: "New York", state: "NY", zip_code: "10001", country: "US") }
  let(:admin) { create(:user, email: "admin@example.com", name: "Admin") }

  describe "#perform!" do
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
      verification = create(:social_connect_verification, user:, platform: "twitter", uid: "12345", handle: "johndoe")
      other_verification = create(:social_connect_verification, platform: "twitter", uid: "12345", handle: "johndoe")

      described_class.new(user, performed_by: admin).perform!

      expect(SocialConnectVerification.exists?(id: verification.id)).to be(false)
      expect(SocialConnectVerification.where(user_id: user.id)).to be_empty
      expect(SocialConnectVerification.where(uid: "12345").pluck(:user_id)).to eq([other_verification.user_id])
      expect(user.reload.twitter_user_id).to be_nil
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
