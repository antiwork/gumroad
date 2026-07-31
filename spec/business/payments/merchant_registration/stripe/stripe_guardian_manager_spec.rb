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
          state: "California",
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
        .and_raise(Stripe::InvalidRequestError.new("No such person: 'person_gone'", nil))
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
    # acceptance — the account sits on the guardian requirement, which is the truthful state. The
    # IP check in person_attributes stays as defence for any future caller that bypasses the gate.
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

      expect(Stripe::Account).not_to have_received(:create_person)
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
        .and_raise(Stripe::InvalidRequestError.new("No such person: 'person_gone'", nil))

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
  end
end
