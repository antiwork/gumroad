# frozen_string_literal: true

require "spec_helper"

describe StripeGuardianManager do
  let(:passphrase) { GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD") }
  let(:stripe_account_id) { "acct_test_guardian" }
  let(:user) { create(:user) }

  # A Stripe::Account, not a MerchantAccount: the sync is handed the object the merchant-account
  # manager already retrieved, so the specs pass the same shape.
  let(:stripe_account) { Stripe::StripeObject.construct_from(id: stripe_account_id) }

  let(:guardian) { create(:guardian, user:, individual_tax_id: "123456789") }

  # 15 years old today, and in the US, so requires_legal_guardian? is true.
  def create_compliance_info(birthday: 15.years.ago.to_date, country: "United States", guardian_record: nil)
    info = create(:user_compliance_info, user:, birthday:, country:)
    UserComplianceInfo.find(info.id).update!(guardian: guardian_record) if guardian_record
    info.reload
  end

  before do
    allow(Stripe::Account).to receive(:create_person).and_return(
      Stripe::StripeObject.construct_from(id: "person_guardian_new")
    )
    allow(Stripe::Account).to receive(:update_person).and_return(
      Stripe::StripeObject.construct_from(id: "person_guardian_existing")
    )
    allow(Stripe::Account).to receive(:list_persons).and_return(Stripe::StripeObject.construct_from(data: []))
  end

  describe ".sync" do
    it "creates a legal-guardian person and records the id Stripe assigns" do
      create_compliance_info(guardian_record: guardian)

      described_class.sync(user, stripe_account, passphrase:)

      sent = nil
      expect(Stripe::Account).to have_received(:create_person) { |_, params| sent = params }
      # The fields Stripe actually verifies, asserted whole rather than by hash_including: a
      # dropped address or dob would otherwise pass and only surface as a stalled verification.
      expect(sent).to include(
        first_name: "Ellie",
        last_name: "Bartowski",
        email: "guardian@example.com",
        phone: "0000000000",
        dob: { day: 4, month: 3, year: 1975 },
        relationship: { legal_guardian: true },
        address: {
          line1: "address_full_match",
          line2: nil,
          city: "San Francisco",
          state: "CA",
          postal_code: "94107",
          country: "US"
        }
      )
      expect(guardian.reload.stripe_person_id).to eq("person_guardian_new")
    end

    it "updates the existing person instead of creating a second one" do
      guardian.update!(stripe_person_id: "person_guardian_existing")
      allow(Stripe::Account).to receive(:retrieve_person).and_return(
        Stripe::StripeObject.construct_from(id: "person_guardian_existing")
      )
      create_compliance_info(guardian_record: guardian)

      described_class.sync(user, stripe_account, passphrase:)

      expect(Stripe::Account).to have_received(:update_person).with(
        stripe_account_id,
        "person_guardian_existing",
        hash_including(first_name: "Ellie", relationship: { legal_guardian: true })
      )
      expect(Stripe::Account).not_to have_received(:create_person)
    end

    # A guardian created by a sync that failed after Stripe had already made the Person: our row has
    # no id, but the account does have one. Creating again would leave two legal-guardian Persons.
    it "finds an existing person by relationship when no id was recorded" do
      allow(Stripe::Account).to receive(:list_persons).and_return(
        Stripe::StripeObject.construct_from(data: [{ id: "person_guardian_orphan" }])
      )
      create_compliance_info(guardian_record: guardian)

      described_class.sync(user, stripe_account, passphrase:)

      expect(Stripe::Account).to have_received(:list_persons).with(
        stripe_account_id, relationship: { legal_guardian: true }, limit: 1
      )
      expect(Stripe::Account).to have_received(:update_person).with(
        stripe_account_id, "person_guardian_orphan", anything
      )
      expect(Stripe::Account).not_to have_received(:create_person)
    end

    # Erasure selects on stripe_person_id, so a guardian reached only by the relationship scan would
    # be skipped by it — leaving the adult's details at Stripe permanently.
    it "records the id of a person it reached by the relationship scan" do
      allow(Stripe::Account).to receive(:list_persons).and_return(
        Stripe::StripeObject.construct_from(data: [{ id: "person_guardian_orphan" }])
      )
      create_compliance_info(guardian_record: guardian)

      described_class.sync(user, stripe_account, passphrase:)

      expect(guardian.reload.stripe_person_id).to eq("person_guardian_orphan")
    end

    # stripe_person_id is uniquely indexed, so adopting a superseded guardian's Person has to clear
    # the old row's id or the save collides.
    it "takes the person id from a superseded guardian rather than colliding on it" do
      superseded = create(:guardian, user:, stripe_person_id: "person_shared")
      superseded.mark_deleted!
      allow(Stripe::Account).to receive(:list_persons).and_return(
        Stripe::StripeObject.construct_from(data: [{ id: "person_shared" }])
      )
      create_compliance_info(guardian_record: guardian)

      described_class.sync(user, stripe_account, passphrase:)

      expect(guardian.reload.stripe_person_id).to eq("person_shared")
      expect(superseded.reload.stripe_person_id).to be_nil
    end

    # The recorded id no longer resolving means the Person was deleted at Stripe. The sync must
    # recover by making a new one rather than failing the seller's save.
    it "creates a fresh person when the recorded id no longer exists at Stripe" do
      guardian.update!(stripe_person_id: "person_gone")
      allow(Stripe::Account).to receive(:retrieve_person)
        .and_raise(Stripe::InvalidRequestError.new("No such person: 'person_gone'", nil, code: "resource_missing"))
      create_compliance_info(guardian_record: guardian)

      described_class.sync(user, stripe_account, passphrase:)

      expect(Stripe::Account).to have_received(:create_person)
      expect(guardian.reload.stripe_person_id).to eq("person_guardian_new")
    end

    it "sends the guardian's own terms acceptance, stamped when they accepted" do
      accepted_at = Time.utc(2026, 5, 4, 12, 0, 0)
      guardian.update!(stripe_tos_accepted: true, stripe_tos_accepted_at: accepted_at, stripe_tos_ip: "203.0.113.7")
      create_compliance_info(guardian_record: guardian)

      described_class.sync(user, stripe_account, passphrase:)

      expect(Stripe::Account).to have_received(:create_person).with(
        stripe_account_id,
        hash_including(
          additional_tos_acceptances: {
            account: { date: accepted_at.to_i, ip: "203.0.113.7" }
          }
        )
      )
    end

    # Stripe records the IP as evidence of where a legal acceptance happened, so a placeholder would
    # be a fabricated attestation. Since has_completed_info? now requires the IP alongside the flag,
    # such a guardian never reaches Stripe at all rather than arriving as a Person with no
    # acceptance — the account sits on the guardian requirement, which is the truthful state.
    it "does not sync a guardian whose acceptance has no IP, so no incomplete person is created" do
      guardian.update!(stripe_tos_accepted: true, stripe_tos_ip: nil)
      create_compliance_info(guardian_record: guardian)

      described_class.sync(user, stripe_account, passphrase:)

      expect(guardian.reload).to have_attributes(has_completed_info?: false, stripe_person_id: nil)
      expect(Stripe::Account).not_to have_received(:create_person)
    end

    it "does not sync a guardian whose acceptance has no timestamp" do
      guardian.update!(stripe_tos_accepted: true, stripe_tos_accepted_at: nil)
      create_compliance_info(guardian_record: guardian)

      described_class.sync(user, stripe_account, passphrase:)

      # Anchored on the predicate so the spec records WHY sync declined, not merely that it did.
      expect(guardian.reload.has_completed_info?).to be(false)
      expect(Stripe::Account).not_to have_received(:create_person)
    end

    # person_hash is only reached through sync today, which gates on has_completed_info?, so this
    # exercises the builder directly: it is the only way to reach the case the guard exists for. A
    # partial acceptance must send no acceptance block at all rather than stamping created_at as the
    # moment of acceptance, which would be an attestation the guardian never made.
    it "sends no terms acceptance when the acceptance is incomplete, rather than inventing a date" do
      guardian.update!(stripe_tos_accepted: true, stripe_tos_accepted_at: nil, stripe_tos_ip: "1.2.3.4")
      compliance_info = create_compliance_info(guardian_record: guardian)

      hash = described_class.send(:person_hash, guardian.reload, compliance_info, passphrase:)

      expect(hash).not_to have_key(:additional_tos_acceptances)
    end

    it "sends the acceptance the guardian actually made when it is complete" do
      accepted_at = 3.days.ago.change(usec: 0)
      guardian.update!(stripe_tos_accepted: true, stripe_tos_accepted_at: accepted_at, stripe_tos_ip: "1.2.3.4")
      compliance_info = create_compliance_info(guardian_record: guardian)

      hash = described_class.send(:person_hash, guardian.reload, compliance_info, passphrase:)

      expect(hash[:additional_tos_acceptances]).to eq(
        account: { date: accepted_at.to_i, ip: "1.2.3.4" }
      )
    end

    context "when there is nothing to sync" do
      it "does nothing for a seller who is over 18" do
        create_compliance_info(birthday: 30.years.ago.to_date, guardian_record: guardian)

        described_class.sync(user, stripe_account, passphrase:)

        expect(Stripe::Account).not_to have_received(:create_person)
        expect(Stripe::Account).not_to have_received(:update_person)
      end

      # The country gate: a minor outside the supported list is never asked for a guardian, so even
      # one already on file must not be sent to Stripe for a verification that cannot succeed.
      it "does nothing for an under-18 seller in an unsupported country" do
        create_compliance_info(country: "Germany", guardian_record: guardian)

        described_class.sync(user, stripe_account, passphrase:)

        expect(Stripe::Account).not_to have_received(:create_person)
      end

      it "does nothing when no guardian is attached" do
        create_compliance_info

        described_class.sync(user, stripe_account, passphrase:)

        expect(Stripe::Account).not_to have_received(:create_person)
      end

      # A partial Person commits the account to a legal-guardian requirement the partial data cannot
      # satisfy, which is worse than sending nothing at all.
      it "does nothing when the guardian's details are incomplete" do
        guardian.update!(street_address: nil)
        create_compliance_info(guardian_record: guardian)

        described_class.sync(user, stripe_account, passphrase:)

        expect(Stripe::Account).not_to have_received(:create_person)
      end

      it "does nothing when the guardian has been soft-deleted" do
        create_compliance_info(guardian_record: guardian)
        guardian.mark_deleted!

        described_class.sync(user, stripe_account, passphrase:)

        expect(Stripe::Account).not_to have_received(:create_person)
      end
    end

    describe "the identity number Stripe validates against the account country" do
      it "sends a 9-digit US identifier as id_number" do
        guardian.update!(individual_tax_id: "123456789")
        create_compliance_info(guardian_record: guardian)

        described_class.sync(user, stripe_account, passphrase:)

        expect(Stripe::Account).to have_received(:create_person).with(
          stripe_account_id, hash_including(id_number: "123456789")
        )
      end

      it "sends a 4-digit US identifier as ssn_last_4" do
        guardian.update!(individual_tax_id: "6789")
        create_compliance_info(guardian_record: guardian)

        described_class.sync(user, stripe_account, passphrase:)

        sent = nil
        expect(Stripe::Account).to have_received(:create_person) { |_, params| sent = params }
        expect(sent[:ssn_last_4]).to eq("6789")
        expect(sent).not_to have_key(:id_number)
      end

      # A foreign guardian has no SSN, so a short foreign identifier must be withheld rather than
      # mislabelled as one — matching the representative's rule.
      it "withholds a 4-digit identifier from a guardian who is not US-resident" do
        guardian.update!(country: "Germany", state: nil, individual_tax_id: "6789")
        create_compliance_info(guardian_record: guardian)

        described_class.sync(user, stripe_account, passphrase:)

        sent = nil
        expect(Stripe::Account).to have_received(:create_person) { |_, params| sent = params }
        expect(sent).not_to have_key(:ssn_last_4)
        expect(sent).not_to have_key(:id_number)
      end

      # Stripe rejects the whole call on a wrongly-sized identifier for a US account, which would
      # take the guardian's other details down with it. Withholding it lets Stripe fall back to
      # document verification instead.
      it "withholds a US identifier that is neither 4 nor 9 digits" do
        guardian.update!(individual_tax_id: "1234567")
        create_compliance_info(guardian_record: guardian)

        described_class.sync(user, stripe_account, passphrase:)

        sent = nil
        expect(Stripe::Account).to have_received(:create_person) { |_, params| sent = params }
        expect(sent).not_to have_key(:id_number)
        expect(sent).not_to have_key(:ssn_last_4)
      end
    end

    # Two overlapping syncs both finding no Person both create one, and only the last id written
    # survives locally — leaving an adult's name, date of birth and address at Stripe with no handle
    # erasure can select on. The lock is the only thing preventing that, so these pin it directly.
    describe "serialization across overlapping syncs" do
      # Returns the pre-lock read first and the live state on every later call, which is exactly the
      # shape sync sees: it reads once to decide whether to take the lock at all, then re-reads
      # inside it. Stubbing a single fixed return would make the in-lock re-read untestable.
      def stub_stale_then_live_compliance_info(stale_info)
        call = 0
        allow(user).to receive(:alive_user_compliance_info) do
          call += 1
          call == 1 ? stale_info : UserComplianceInfo.alive.where(user_id: user.id).last
        end
      end

      it "does not create a second person when a concurrent sync already recorded one" do
        info = create_compliance_info(guardian_record: guardian)
        # The pre-lock read, still showing no recorded id. By the time this sync gets the lock the
        # sync it waited on has created the Person and written the id below. Without the re-read
        # inside the lock this sync still sees no id and creates a duplicate Person.
        stale_info = UserComplianceInfo.find(info.id)
        # Preloaded so the stale read really is stale. Without this the association lazy-loads on
        # first touch INSIDE the lock, which reads the sibling's write no matter what the production
        # code does — and the example passes with the in-lock re-read reverted.
        stale_info.guardian
        Guardian.where(id: guardian.id).update_all(stripe_person_id: "person_from_sibling")
        stub_stale_then_live_compliance_info(stale_info)
        allow(Stripe::Account).to receive(:retrieve_person).and_return(
          Stripe::StripeObject.construct_from(id: "person_from_sibling")
        )

        described_class.sync(user, stripe_account, passphrase:)

        expect(Stripe::Account).not_to have_received(:create_person)
        expect(Stripe::Account).to have_received(:update_person).with(
          stripe_account_id, "person_from_sibling", anything
        )
      end

      it "holds the lock for the whole lookup-create-adopt sequence" do
        create_compliance_info(guardian_record: guardian)
        held = nil
        allow(Stripe::Account).to receive(:create_person) do
          held = $redis.get("stripe_guardian_sync:#{stripe_account_id}")
          Stripe::StripeObject.construct_from(id: "person_guardian_new")
        end

        described_class.sync(user, stripe_account, passphrase:)

        expect(held).to be_present
        expect($redis.get("stripe_guardian_sync:#{stripe_account_id}")).to be_nil
      end

      # Failing closed: a missed sync self-heals on the next account update, an unserialized one
      # leaves an untracked Person holding a third party's identity data at Stripe.
      it "sends nothing to Stripe when the lock is already held" do
        create_compliance_info(guardian_record: guardian)
        stub_const("#{described_class}::SYNC_LOCK_WAIT_TIMEOUT", 0.seconds)
        $redis.set("stripe_guardian_sync:#{stripe_account_id}", "someone-else")

        expect { described_class.sync(user, stripe_account, passphrase:) }
          .to raise_error(StripeGuardianManager::SyncLockUnavailable)
        expect(Stripe::Account).not_to have_received(:create_person)
        # The other holder's lock must survive: releasing it would let both syncs run after all.
        expect($redis.get("stripe_guardian_sync:#{stripe_account_id}")).to eq("someone-else")
      end

      # Callers select on SyncLockUnavailable to remediate. A raw Redis error escapes that and is
      # handled generically, which for erasure means the guardian's data stays at Stripe untracked.
      it "reports Redis being unreachable as a lock failure, not a Redis error" do
        create_compliance_info(guardian_record: guardian)
        allow($redis).to receive(:set).and_raise(Redis::CannotConnectError, "no connection")

        expect { described_class.sync(user, stripe_account, passphrase:) }
          .to raise_error(StripeGuardianManager::SyncLockUnavailable, /Redis unavailable/)
        expect(Stripe::Account).not_to have_received(:create_person)
      end

      it "reports a RedisClient error as a lock failure too" do
        create_compliance_info(guardian_record: guardian)
        allow($redis).to receive(:set).and_raise(RedisClient::ConnectionError, "closed")

        expect { described_class.sync(user, stripe_account, passphrase:) }
          .to raise_error(StripeGuardianManager::SyncLockUnavailable)
        expect(Stripe::Account).not_to have_received(:create_person)
      end

      # The protected work has already run by then, so raising would misreport a completed sync as
      # a lock failure. The lock just stands until its TTL.
      it "does not fail the sync when only the lock release fails" do
        create_compliance_info(guardian_record: guardian)
        allow(Stripe::Account).to receive(:create_person)
          .and_return(Stripe::StripeObject.construct_from(id: "person_guardian_new"))
        allow($redis).to receive(:eval).and_raise(Redis::CannotConnectError, "no connection")

        expect { described_class.sync(user, stripe_account, passphrase:) }.not_to raise_error
        expect(guardian.reload.stripe_person_id).to eq("person_guardian_new")
      end

      # A long lease makes lock expiry rare; it cannot make an orphan impossible. No lock spans the
      # gap between Stripe accepting the create and the id reaching our row, so the guarantee has to
      # be after-the-fact detection.
      it "deletes a legal-guardian person on the account that no local row points at" do
        create_compliance_info(guardian_record: guardian)
        allow(Stripe::Account).to receive(:delete_person)
        allow(Stripe::Account).to receive(:create_person)
          .and_return(Stripe::StripeObject.construct_from(id: "person_guardian_new"))
        allow(Stripe::Account).to receive(:list_persons).and_return(
          Stripe::ListObject.construct_from(data: []),
          Stripe::ListObject.construct_from(
            data: [{ id: "person_guardian_new" }, { id: "person_orphaned_duplicate" }]
          )
        )

        described_class.sync(user, stripe_account, passphrase:)

        expect(Stripe::Account).to have_received(:delete_person)
          .with(stripe_account_id, "person_orphaned_duplicate")
        # The Person this sync just recorded must survive — deleting it would leave the account on an
        # unmet legal-guardian requirement.
        expect(Stripe::Account).not_to have_received(:delete_person)
          .with(stripe_account_id, "person_guardian_new")
      end

      # One refused delete must not abandon the orphans after it. The method-level rescue sits
      # OUTSIDE the enumeration, so a raise on the first orphan skipped every later one — an adult's
      # identity data left at Stripe with no local handle anything reaches.
      it "keeps deleting later orphans when one delete is refused" do
        create_compliance_info(guardian_record: guardian)
        allow(ErrorNotifier).to receive(:notify)
        allow(Stripe::Account).to receive(:create_person)
          .and_return(Stripe::StripeObject.construct_from(id: "person_guardian_new"))
        allow(Stripe::Account).to receive(:list_persons).and_return(
          Stripe::ListObject.construct_from(data: []),
          Stripe::ListObject.construct_from(
            data: [{ id: "person_orphan_refused" }, { id: "person_orphan_second" }]
          )
        )
        allow(Stripe::Account).to receive(:delete_person)
        allow(Stripe::Account).to receive(:delete_person)
          .with(stripe_account_id, "person_orphan_refused")
          .and_raise(Stripe::APIError.new("Stripe is down"))

        described_class.sync(user, stripe_account, passphrase:)

        expect(Stripe::Account).to have_received(:delete_person)
          .with(stripe_account_id, "person_orphan_second")
        expect(ErrorNotifier).to have_received(:notify).with(instance_of(Stripe::APIError))
      end

      # Another guardian row of the same seller holding the id is a local pointer too. Erasure can
      # reach that Person, so deleting it here would destroy a superseded guardian's only handle.
      it "keeps a person another guardian row of the same seller points at" do
        create_compliance_info(guardian_record: guardian)
        create(:guardian, user:, stripe_person_id: "person_previous_guardian")
        allow(Stripe::Account).to receive(:delete_person)
        allow(Stripe::Account).to receive(:create_person)
          .and_return(Stripe::StripeObject.construct_from(id: "person_guardian_new"))
        allow(Stripe::Account).to receive(:list_persons).and_return(
          Stripe::ListObject.construct_from(data: []),
          Stripe::ListObject.construct_from(
            data: [{ id: "person_guardian_new" }, { id: "person_previous_guardian" }]
          )
        )

        described_class.sync(user, stripe_account, passphrase:)

        expect(Stripe::Account).not_to have_received(:delete_person)
      end

      # The reconcile deletes what it does not find recorded, so a Person past the first page is an
      # orphan holding an adult's identity data that no scan ever revisits.
      it "deletes an orphaned person beyond the first page of Stripe's results" do
        create_compliance_info(guardian_record: guardian)
        allow(Stripe::Account).to receive(:delete_person)
        allow(Stripe::Account).to receive(:create_person)
          .and_return(Stripe::StripeObject.construct_from(id: "person_guardian_new"))
        allow(Stripe::Account).to receive(:list_persons) do |_account_id, params|
          # limit: 1 is existing_person's own lookup, which must stay empty so the sync creates.
          if params[:limit] == 1
            Stripe::ListObject.construct_from(data: [])
          elsif params[:starting_after] == "person_guardian_new"
            Stripe::ListObject.construct_from(data: [{ id: "person_orphan_page_two" }], has_more: false)
          else
            Stripe::ListObject.construct_from(data: [{ id: "person_guardian_new" }], has_more: true)
          end
        end

        described_class.sync(user, stripe_account, passphrase:)

        expect(Stripe::Account).to have_received(:delete_person)
          .with(stripe_account_id, "person_orphan_page_two")
        expect(Stripe::Account).not_to have_received(:delete_person)
          .with(stripe_account_id, "person_guardian_new")
      end

      # An unread page holds orphans nothing local points at, so erasure's recorded-id path cannot
      # select them. A later sync's reconcile does rescan, so a one-off glitch self-heals; a
      # persistent one fails every rescan, on an account whose next write may never come.
      it "reports an incomplete scan when Stripe promises more persons but returns no cursor" do
        create_compliance_info(guardian_record: guardian)
        allow(ErrorNotifier).to receive(:notify)
        allow(Stripe::Account).to receive(:delete_person)
        allow(Stripe::Account).to receive(:create_person)
          .and_return(Stripe::StripeObject.construct_from(id: "person_guardian_new"))
        allow(Stripe::Account).to receive(:list_persons) do |_account_id, params|
          if params[:limit] == 1
            Stripe::ListObject.construct_from(data: [])
          else
            # has_more with an empty page: Stripe says there are more and hands back nothing to
            # page on, so the orphans it is describing can never be read.
            Stripe::ListObject.construct_from(data: [], has_more: true)
          end
        end

        expect(described_class.sync(user, stripe_account, passphrase:).id).to eq("person_guardian_new")

        expect(ErrorNotifier).to have_received(:notify)
          .with(/reconciliation scanned only part of Stripe account #{stripe_account_id}/)
        expect(user.reload.comments.last.content)
          .to include("Guardian reconciliation scan incomplete on Stripe account #{stripe_account_id}")
      end

      # The other incomplete arm: a page whose last id is the cursor we just sent. That is the
      # infinite-loop guard, so it is the arm most at risk from a later edit to the pagination loop.
      it "reports an incomplete scan when Stripe keeps returning the page we already paged past" do
        create_compliance_info(guardian_record: guardian)
        allow(ErrorNotifier).to receive(:notify)
        allow(Stripe::Account).to receive(:delete_person)
        allow(Stripe::Account).to receive(:create_person)
          .and_return(Stripe::StripeObject.construct_from(id: "person_guardian_new"))
        allow(Stripe::Account).to receive(:list_persons) do |_account_id, params|
          if params[:limit] == 1
            Stripe::ListObject.construct_from(data: [])
          else
            Stripe::ListObject.construct_from(data: [{ id: "person_stuck" }], has_more: true)
          end
        end

        described_class.sync(user, stripe_account, passphrase:)

        expect(ErrorNotifier).to have_received(:notify)
          .with(/reconciliation scanned only part of Stripe account #{stripe_account_id}/)
        # Bounded: the first reconcile page, then the one request that proves the cursor is stuck.
        expect(Stripe::Account).to have_received(:list_persons)
          .with(stripe_account_id, hash_including(limit: 100)).twice
      end

      # The reporting itself must not be able to fail the sync: the method-level rescue notifies too,
      # so a notifier that is down would raise out of the handler and abort account creation.
      it "still completes the sync when reporting the incomplete scan raises" do
        create_compliance_info(guardian_record: guardian)
        allow(ErrorNotifier).to receive(:notify).and_raise(StandardError.new("sentry down"))
        allow(Stripe::Account).to receive(:delete_person)
        allow(Stripe::Account).to receive(:create_person)
          .and_return(Stripe::StripeObject.construct_from(id: "person_guardian_new"))
        allow(Stripe::Account).to receive(:list_persons) do |_account_id, params|
          if params[:limit] == 1
            Stripe::ListObject.construct_from(data: [])
          else
            Stripe::ListObject.construct_from(data: [], has_more: true)
          end
        end

        expect(described_class.sync(user, stripe_account, passphrase:).id).to eq("person_guardian_new")

        # The durable half is written first, so it survives the notifier being down.
        expect(user.reload.comments.last.content)
          .to include("Guardian reconciliation scan incomplete on Stripe account #{stripe_account_id}")
      end

      # The complement: a scan that finished having deleted nothing is the ordinary case and must
      # stay silent, or the alert it raises above means nothing.
      it "stays silent when the scan completes with no orphans" do
        create_compliance_info(guardian_record: guardian)
        allow(ErrorNotifier).to receive(:notify)
        allow(Stripe::Account).to receive(:create_person)
          .and_return(Stripe::StripeObject.construct_from(id: "person_guardian_new"))
        allow(Stripe::Account).to receive(:list_persons) do |_account_id, params|
          if params[:limit] == 1
            Stripe::ListObject.construct_from(data: [])
          else
            Stripe::ListObject.construct_from(data: [{ id: "person_guardian_new" }], has_more: false)
          end
        end

        described_class.sync(user, stripe_account, passphrase:)

        expect(ErrorNotifier).not_to have_received(:notify)
        expect(user.reload.comments).to be_empty
      end

      # existing_person takes ONE Person, so an account already holding several legal-guardian
      # Persons had the rest left standing when the reconcile only ran after a create. No later sync
      # revisits them either — the next one takes the now-recorded id and never scans.
      it "deletes the extra persons when it adopted the first of several on the account" do
        create_compliance_info(guardian_record: guardian)
        allow(Stripe::Account).to receive(:delete_person)
        allow(Stripe::Account).to receive(:list_persons) do |_account_id, params|
          people = [{ id: "person_guardian_first" }, { id: "person_guardian_second" }]
          Stripe::ListObject.construct_from(data: params[:limit] == 1 ? [people.first] : people)
        end

        described_class.sync(user, stripe_account, passphrase:)

        expect(Stripe::Account).not_to have_received(:create_person)
        expect(guardian.reload.stripe_person_id).to eq("person_guardian_first")
        expect(Stripe::Account).to have_received(:delete_person)
          .with(stripe_account_id, "person_guardian_second")
        # The adopted Person is the one satisfying the account's requirement.
        expect(Stripe::Account).not_to have_received(:delete_person)
          .with(stripe_account_id, "person_guardian_first")
      end

      # The steady-state path: a guardian with a recorded id syncs by update on every account write,
      # so this is where an orphan from any earlier failure gets its only further chance of being
      # noticed.
      it "deletes an orphan on the update path taken by a guardian with a recorded id" do
        guardian.update!(stripe_person_id: "person_guardian_existing")
        create_compliance_info(guardian_record: guardian)
        allow(Stripe::Account).to receive(:delete_person)
        allow(Stripe::Account).to receive(:retrieve_person).and_return(
          Stripe::StripeObject.construct_from(id: "person_guardian_existing")
        )
        allow(Stripe::Account).to receive(:list_persons).and_return(
          Stripe::ListObject.construct_from(
            data: [{ id: "person_guardian_existing" }, { id: "person_orphaned_duplicate" }]
          )
        )

        described_class.sync(user, stripe_account, passphrase:)

        expect(Stripe::Account).to have_received(:update_person)
          .with(stripe_account_id, "person_guardian_existing", anything)
        expect(Stripe::Account).to have_received(:delete_person)
          .with(stripe_account_id, "person_orphaned_duplicate")
        expect(Stripe::Account).not_to have_received(:delete_person)
          .with(stripe_account_id, "person_guardian_existing")
      end

      # The reconcile deletes what no local row points at, so running it before adopt_person_id!
      # would delete the Person this sync had just reached by scan and was about to record.
      it "keeps the person it adopted by relationship scan rather than reconciling it away" do
        create_compliance_info(guardian_record: guardian)
        allow(Stripe::Account).to receive(:delete_person)
        allow(Stripe::Account).to receive(:list_persons).and_return(
          Stripe::ListObject.construct_from(data: [{ id: "person_guardian_orphan" }])
        )

        described_class.sync(user, stripe_account, passphrase:)

        expect(guardian.reload.stripe_person_id).to eq("person_guardian_orphan")
        expect(Stripe::Account).not_to have_received(:delete_person)
      end

      # The Person the caller asked for exists and its id is recorded by this point. Failing the sync
      # over the cleanup would turn a resolved duplicate into an unmet Stripe requirement.
      it "still returns the created person when the reconcile fails" do
        create_compliance_info(guardian_record: guardian)
        allow(ErrorNotifier).to receive(:notify)
        allow(Stripe::Account).to receive(:create_person)
          .and_return(Stripe::StripeObject.construct_from(id: "person_guardian_new"))
        allow(Stripe::Account).to receive(:list_persons).and_return(
          Stripe::ListObject.construct_from(data: [])
        )
        allow(Stripe::Account).to receive(:list_persons)
          .with(stripe_account_id, hash_including(limit: 100))
          .and_raise(Stripe::APIError.new("Stripe is down"))

        expect(described_class.sync(user, stripe_account, passphrase:).id).to eq("person_guardian_new")
        expect(guardian.reload.stripe_person_id).to eq("person_guardian_new")
        expect(ErrorNotifier).to have_received(:notify)
      end

      # The scan and the reconcile are account-scoped, so a lock scoped to one guardian row does not
      # cover them: guardian_id is mutable on a live compliance revision, so two syncs of the same
      # seller can carry different guardian rows, and then the reconcile of one deletes the Person
      # the other created but had not yet recorded.
      it "excludes a concurrent sync carrying a different guardian row of the same seller" do
        create_compliance_info(guardian_record: guardian)
        other_guardian = create(:guardian, user:)
        allow(Stripe::Account).to receive(:delete_person)
        $redis.set("stripe_guardian_sync:#{stripe_account_id}", "sync-holding-other-guardian")
        stub_const("#{described_class}::SYNC_LOCK_WAIT_TIMEOUT", 0.seconds)

        expect { described_class.sync(user, stripe_account, passphrase:) }
          .to raise_error(StripeGuardianManager::SyncLockUnavailable)
        expect(Stripe::Account).not_to have_received(:create_person)
        expect(Stripe::Account).not_to have_received(:delete_person)
        expect(other_guardian.reload.stripe_person_id).to be_nil
      end

      # The lock orders sync against erasure, but ordering alone is not enough on the sync's side: a
      # sync that read the guardian before erasure ran and won the lock after it would re-send the
      # adult's details to Stripe with the erasure already reported complete. The reload inside the
      # lock is what catches that — an anonymized row is never complete.
      it "sends nothing to Stripe when the guardian was erased while this sync waited" do
        info = create_compliance_info(guardian_record: guardian)
        # The pre-lock read the sync is holding, still fully populated. The row underneath it is what
        # erasure left.
        stale_info = UserComplianceInfo.find(info.id)
        stale_info.guardian
        guardian.anonymize!
        stub_stale_then_live_compliance_info(stale_info)

        expect(described_class.sync(user, stripe_account, passphrase:)).to be_nil
        expect(Stripe::Account).not_to have_received(:create_person)
        expect(Stripe::Account).not_to have_received(:update_person)
      end

      # Everything the payload is built from is re-derived inside the lock, not just the guardian
      # row. A compliance update REPLACES the live revision — the old one is soft-deleted and a new
      # one created — so a sync holding the pre-lock read is holding a revision that no longer
      # decides anything. These three are the shapes where acting on it exports data the current
      # compliance state does not authorize.
      it "does not sync a guardian the current compliance revision no longer selects" do
        superseded_info = create_compliance_info(guardian_record: guardian)
        replacement_guardian = create(:guardian, user:, email: "current@example.com")
        # What a compliance update leaves behind: the revision the sync read is dead, and the live
        # one points at a different guardian.
        superseded_info.mark_deleted!
        create_compliance_info(guardian_record: replacement_guardian)

        allow(user).to receive(:alive_user_compliance_info).and_return(
          superseded_info, UserComplianceInfo.alive.where(user_id: user.id).last
        )

        described_class.sync(user, stripe_account, passphrase:)

        sent = nil
        expect(Stripe::Account).to have_received(:create_person) { |_, params| sent = params }
        expect(sent[:email]).to eq("current@example.com")
        expect(replacement_guardian.reload.stripe_person_id).to eq("person_guardian_new")
        # The guardian the requirement no longer names keeps no Stripe handle, because nothing of
        # theirs was sent.
        expect(guardian.reload.stripe_person_id).to be_nil
      end

      # The requirement itself can end while the sync waits — a corrected birthday, or a move to a
      # country with no guardian path. Then the guardian's identity data must not reach Stripe at
      # all, and the pre-lock check cannot know that yet.
      it "sends nothing when the guardian requirement was dropped while this sync waited" do
        stale_info = create_compliance_info(guardian_record: guardian)
        stale_info.mark_deleted!
        create_compliance_info(birthday: 30.years.ago.to_date, guardian_record: guardian)

        allow(user).to receive(:alive_user_compliance_info).and_return(
          stale_info, UserComplianceInfo.alive.where(user_id: user.id).last
        )

        expect(described_class.sync(user, stripe_account, passphrase:)).to be_nil
        expect(Stripe::Account).not_to have_received(:create_person)
        expect(Stripe::Account).not_to have_received(:update_person)
      end

      # The revision also decides how the tax identifier is LABELLED: Stripe validates it against the
      # ACCOUNT country, so the same 4 digits are an ssn_last_4 on a US account and an id_number
      # anywhere else. A stale revision saying US mislabels it, and Stripe then verifies it against
      # the wrong directory and fails the guardian permanently with a generic mismatch.
      it "labels the tax identifier against the current compliance country" do
        guardian.update!(individual_tax_id: "6789")
        stale_info = create_compliance_info(guardian_record: guardian)
        stale_info.mark_deleted!
        create_compliance_info(country: "Australia", guardian_record: guardian)
        # The country gate would otherwise drop the requirement along with the country change, which
        # is the separate case above; here the requirement stands and only the labelling moves.
        allow_any_instance_of(UserComplianceInfo).to receive(:requires_legal_guardian?).and_return(true)

        allow(user).to receive(:alive_user_compliance_info).and_return(
          stale_info, UserComplianceInfo.alive.where(user_id: user.id).last
        )

        described_class.sync(user, stripe_account, passphrase:)

        sent = nil
        expect(Stripe::Account).to have_received(:create_person) { |_, params| sent = params }
        expect(sent[:id_number]).to eq("6789")
        expect(sent).not_to have_key(:ssn_last_4)
      end

      # The lease is held across two Stripe round trips, so a TTL shorter than a worst-case call
      # expires mid-sequence and lets a second sync create the duplicate Person this lock exists to
      # prevent — during a Stripe brownout, which is when overlapping syncs are most likely. Pinned
      # against the client's own worst case rather than a bare number.
      it "outlives the slowest Stripe call the client will make" do
        worst_case_stripe_call = Stripe.read_timeout * (Stripe.max_network_retries + 1)

        expect(described_class::SYNC_LOCK_TTL).to be > worst_case_stripe_call.seconds
        # Both round trips under one lock.
        expect(described_class::SYNC_LOCK_TTL).to be > (worst_case_stripe_call * 2).seconds
      end
    end
  end

  describe ".delete_person" do
    it "deletes the person from Stripe" do
      guardian.update!(stripe_person_id: "person_to_delete")
      allow(Stripe::Account).to receive(:delete_person)

      expect(described_class.delete_person(guardian, stripe_account_id)).to be(true)
      expect(Stripe::Account).to have_received(:delete_person).with(stripe_account_id, "person_to_delete")
    end

    it "does nothing when no person was ever created" do
      allow(Stripe::Account).to receive(:delete_person)

      expect(described_class.delete_person(guardian, stripe_account_id)).to be(false)
      expect(Stripe::Account).not_to have_received(:delete_person)
    end

    it "treats an already-deleted person as deleted" do
      guardian.update!(stripe_person_id: "person_gone")
      allow(Stripe::Account).to receive(:delete_person)
        .and_raise(Stripe::InvalidRequestError.new("No such person: 'person_gone'", nil, code: "resource_missing"))

      expect(described_class.delete_person(guardian, stripe_account_id)).to be(true)
    end

    # An undeleted Person means the guardian's details still sit with Stripe after we told the seller
    # they were erased, so anything other than "already gone" has to surface.
    it "raises on any other Stripe failure" do
      guardian.update!(stripe_person_id: "person_locked")
      allow(Stripe::Account).to receive(:delete_person)
        .and_raise(Stripe::InvalidRequestError.new("Cannot delete the account representative", nil))

      expect { described_class.delete_person(guardian, stripe_account_id) }
        .to raise_error(Stripe::InvalidRequestError)
    end

    # The missing-resource test is the structured CODE, not the message. A refusal whose message
    # happens to contain the phrase but carries a different code is a live failure, and treating it
    # as "already gone" is how an erasure reports itself fulfilled with the Person still at Stripe.
    it "raises when the message says no such person but the code does not" do
      guardian.update!(stripe_person_id: "person_locked")
      allow(Stripe::Account).to receive(:delete_person).and_raise(
        Stripe::InvalidRequestError.new("No such person could be modified", nil, code: "account_invalid")
      )

      expect { described_class.delete_person(guardian, stripe_account_id) }
        .to raise_error(Stripe::InvalidRequestError)
    end

    # A missing ACCOUNT is not a confirmed deletion — erasure reconciles false as unconfirmed and
    # retries it, so this must stay distinguishable from the already-gone Person above.
    it "reports a missing account as unconfirmed rather than deleted" do
      guardian.update!(stripe_person_id: "person_on_dead_account")
      allow(Stripe::Account).to receive(:delete_person).and_raise(
        Stripe::InvalidRequestError.new("No such account: 'acct_dead'", nil, code: "resource_missing")
      )

      expect(described_class.delete_person(guardian, stripe_account_id)).to be(false)
    end
  end

  describe "looking up the recorded person" do
    # The retrieve fall-through tests the structured code, not just the message. An unrelated Stripe
    # refusal whose message happens to contain the phrase would otherwise be read as "the Person is
    # gone" and silently create a duplicate holding the adult's identity data.
    it "raises rather than creating a duplicate when the message matches but the code does not" do
      guardian.update!(stripe_person_id: "person_recorded")
      create_compliance_info(guardian_record: guardian)
      allow(Stripe::Account).to receive(:retrieve_person).and_raise(
        Stripe::InvalidRequestError.new("No such person may be modified", nil, code: "account_invalid")
      )

      expect { described_class.sync(user, stripe_account, passphrase:) }
        .to raise_error(Stripe::InvalidRequestError)
      expect(Stripe::Account).not_to have_received(:create_person)
    end
  end

  describe "recording the Stripe person id" do
    # The superseded-row clear is scoped to the seller. Unscoped it would null stripe_person_id on
    # ANOTHER seller's guardian row holding that id, destroying their only erasure handle — the row
    # would then look never-synced while their adult's details stayed at Stripe.
    it "does not clear another seller's guardian row holding the same person id" do
      other_seller = create(:user)
      other_guardian = create(:guardian, user: other_seller, stripe_person_id: "person_shared")
      create_compliance_info(guardian_record: guardian)
      allow(Stripe::Account).to receive(:create_person)
        .and_return(Stripe::StripeObject.construct_from(id: "person_shared"))

      # The unique index is what should complain about a cross-user holder, loudly, rather than this
      # silently adopting the id out from under them.
      expect { described_class.sync(user, stripe_account, passphrase:) }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect(other_guardian.reload.stripe_person_id).to eq("person_shared")
    end
  end
end
