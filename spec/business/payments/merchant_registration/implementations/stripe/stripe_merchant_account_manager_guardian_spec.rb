# frozen_string_literal: true

require "spec_helper"

RSpec.describe StripeMerchantAccountManager, type: :service do
  describe "guardian functionality" do
    let(:user) { create(:user) }
    let!(:tos_agreement) { create(:tos_agreement, user: user) }
    let!(:user_compliance_info) do
      create(:user_compliance_info,
        user: user,
        birthday: 16.years.ago,
        individual_tax_id: "123456789",
        guardian_first_name: "John",
        guardian_last_name: "Doe",
        guardian_email: "john@example.com",
        guardian_phone: "+1234567890",
        guardian_street_address: "123 Main St",
        guardian_city: "Anytown",
        guardian_state: "CA",
        guardian_zip_code: "12345",
        guardian_date_of_birth: 40.years.ago,
        guardian_individual_tax_id: "123456789",
        guardian_stripe_tos_accepted: true,
        guardian_stripe_processing_tos_accepted: true,
        country: "United States"
      )
    end
    let(:merchant_account) { create(:merchant_account, user: user) }
    let(:stripe_account) {
      double("Stripe::Account",
        id: "acct_123",
        "[]" => {"user_compliance_info_id" => "123"},
        capabilities: double("capabilities", keys: [])
      )
    }
    let(:passphrase) { "test_passphrase" }

    before do
      allow(Stripe::Account).to receive(:create).and_return(stripe_account)
      allow(Stripe::Account).to receive(:list_persons).and_return({"data" => []})
      allow(Stripe::Account).to receive(:create_person)
      allow(Stripe::Account).to receive(:update_person)
      allow(Stripe::Account).to receive(:update)
      allow(Stripe::Account).to receive(:retrieve_person).and_return({
        "id" => "person_123",
        "relationship" => { "representative" => true, "owner" => false },
        "first_name" => "John",
        "last_name" => "Doe",
        "email" => "john@example.com",
        "phone" => "+1234567890",
        "dob" => { "day" => 15, "month" => 6, "year" => 1985 },
        "address" => {
          "line1" => "123 Main St",
          "city" => "Anytown",
          "state" => "CA",
          "postal_code" => "12345",
          "country" => "US"
        }
      })

      # Mock the person_hash method to avoid encryption issues
      allow(described_class).to receive(:person_hash).and_return({
        first_name: "Test",
        last_name: "User",
        email: "test@example.com",
        phone: "+1234567890",
        dob: {
          day: 1,
          month: 1,
          year: 2000
        }
      })

      # Mock ActiveRecord relations
      allow(user.user_compliance_info_requests).to receive(:requested).and_return(double("relation"))
      allow(user.user_compliance_info_requests.requested).to receive(:where).and_return(double("relation"))
      allow(user.user_compliance_info_requests.requested.where).to receive(:find_each)
    end

    describe ".create_account" do
      context "when user is under 18 and guardian fields are complete" do
        before do
          user_compliance_info.update!(
            guardian_first_name: "John",
            guardian_last_name: "Doe",
            guardian_email: "john@example.com",
            guardian_phone: "+1234567890",
            guardian_street_address: "123 Main St",
            guardian_city: "Anytown",
            guardian_date_of_birth: 30.years.ago,
            guardian_stripe_tos_accepted: true,
            guardian_stripe_processing_tos_accepted: true
          )
        end

        it "creates guardian person in Stripe" do
          expect(Stripe::Account).to receive(:create_person).with(
            stripe_account.id,
            hash_including(
              first_name: "John",
              last_name: "Doe",
              email: "john@example.com",
              phone: "+1234567890",
              relationship: {
                representative: true,
                owner: false,
                title: "Legal Guardian"
              }
            )
          )

          described_class.create_account(user, passphrase: passphrase)
        end
      end

      context "when user is under 18 but guardian fields are incomplete" do
        it "does not create guardian person in Stripe" do
          expect(Stripe::Account).not_to receive(:create_person).with(
            stripe_account.id,
            hash_including(relationship: { representative: true, owner: false })
          )

          described_class.create_account(user, passphrase: passphrase)
        end
      end

      context "when user is 18 or older" do
        let(:adult_user) { create(:user) }
        let!(:adult_tos_agreement) { create(:tos_agreement, user: adult_user) }
        let!(:adult_compliance_info) { create(:user_compliance_info, user: adult_user, birthday: 20.years.ago) }

        before do
          allow(adult_user).to receive(:native_payouts_supported?).and_return(true)
        end

        it "does not create guardian person in Stripe" do
          expect(Stripe::Account).not_to receive(:create_person).with(
            stripe_account.id,
            hash_including(relationship: { representative: true, owner: false })
          )

          described_class.create_account(adult_user, passphrase: passphrase)
        end
      end
    end

    describe ".update_account" do
        let(:last_user_compliance_info) do
          create(:user_compliance_info,
            user: user,
            birthday: 16.years.ago,
            guardian_first_name: "John",
            guardian_last_name: "Doe",
            guardian_email: "john@example.com",
            guardian_phone: "+1234567890",
            guardian_street_address: "123 Main St",
            guardian_city: "Anytown",
            guardian_state: "CA",
            guardian_zip_code: "12345",
            guardian_date_of_birth: 40.years.ago,
            guardian_individual_tax_id: "123456789",
            guardian_stripe_tos_accepted: true,
            guardian_stripe_processing_tos_accepted: true,
            country: "United States"
          )
        end

      before do
        allow(user).to receive(:stripe_account).and_return(merchant_account)
        allow(merchant_account).to receive(:charge_processor_merchant_id).and_return("acct_123")
        allow(Stripe::Account).to receive(:retrieve).and_return(stripe_account)
      end

      context "when user is under 18 and guardian fields are complete" do
        before do
          user_compliance_info.update!(
            guardian_first_name: "John",
            guardian_last_name: "Doe",
            guardian_email: "john@example.com",
            guardian_phone: "+1234567890",
            guardian_street_address: "123 Main St",
            guardian_city: "Anytown",
            guardian_date_of_birth: 30.years.ago,
            guardian_stripe_tos_accepted: true,
            guardian_stripe_processing_tos_accepted: true
          )
        end

        it "calls update_guardian_person" do
          expect(described_class).to receive(:update_guardian_person).with(user, stripe_account, passphrase)

          described_class.update_account(user, passphrase: passphrase)
        end
      end

      context "when user is under 18 but guardian fields are incomplete" do
        before do
          user_compliance_info.update_column(:guardian_first_name, nil)
          user_compliance_info.update_column(:guardian_last_name, nil)
          user_compliance_info.update_column(:guardian_email, nil)
        end

        it "does not call update_guardian_person" do
          expect(described_class).not_to receive(:update_guardian_person)

          described_class.update_account(user, passphrase: passphrase)
        end
      end

      context "when user is 18 or older" do
        let(:adult_user) { create(:user) }
        let!(:adult_tos_agreement) { create(:tos_agreement, user: adult_user) }
        let!(:adult_merchant_account) { create(:merchant_account, user: adult_user) }
        let!(:adult_compliance_info) { create(:user_compliance_info, user: adult_user, birthday: 20.years.ago) }

        before do
          allow(adult_user).to receive(:native_payouts_supported?).and_return(true)
        end

        it "does not call update_guardian_person" do
          expect(described_class).not_to receive(:update_guardian_person)

          described_class.update_account(adult_user, passphrase: passphrase)
        end
      end
    end

    describe ".update_guardian_person" do
      let(:guardian_person) do
        {
          "id" => "person_123",
          "relationship" => { "representative" => true, "owner" => false }
        }
      end

      before do
        allow(Stripe::Account).to receive(:list_persons).and_return({"data" => [guardian_person]})
        allow(Stripe::Account).to receive(:retrieve_person).and_return(
          double("Stripe::Person",
            first_name: "Old",
            last_name: "Name",
            email: "old@example.com",
            phone: "+0987654321",
            dob: { day: 1, month: 1, year: 1980 },
            address: { line1: "Old Address" },
            id_number: "old_id",
            ssn_last_4: "1234"
          )
        )
      end

      context "when guardian person exists" do
        before do
          user_compliance_info.update!(
            guardian_first_name: "John",
            guardian_last_name: "Doe",
            guardian_email: "john@example.com",
            guardian_phone: "+1234567890",
            guardian_street_address: "123 Main St",
            guardian_city: "Anytown",
            guardian_date_of_birth: 30.years.ago,
            guardian_individual_tax_id: "5678"
          )
        end

        it "updates existing guardian person" do
          # Mock retrieve_person to return a hash
          allow(Stripe::Account).to receive(:retrieve_person).and_return({
            "id" => "person_123",
            "relationship" => { "representative" => true, "owner" => false },
            "first_name" => "John",
            "last_name" => "Doe",
            "email" => "john@example.com",
            "phone" => "+1234567890",
            "dob" => { "day" => 15, "month" => 6, "year" => 1985 },
            "address" => {
              "line1" => "123 Main St",
              "city" => "Anytown",
              "state" => "CA",
              "postal_code" => "12345",
              "country" => "US"
            }
          })

          expect(Stripe::Account).to receive(:update_person).with(
            stripe_account.id,
            guardian_person["id"],
            hash_including(
              relationship: {
                representative: true,
                owner: false,
                title: "Legal Guardian"
              }
            )
          )

          described_class.update_guardian_person(user, stripe_account, passphrase)
        end

        it "handles Stripe errors gracefully" do
          # Mock retrieve_person to return a hash
          allow(Stripe::Account).to receive(:retrieve_person).and_return({
            "id" => "person_123",
            "relationship" => { "representative" => true, "owner" => false },
            "first_name" => "John",
            "last_name" => "Doe",
            "email" => "john@example.com",
            "phone" => "+1234567890",
            "dob" => { "day" => 15, "month" => 6, "year" => 1985 },
            "address" => {
              "line1" => "123 Main St",
              "city" => "Anytown",
              "state" => "CA",
              "postal_code" => "12345",
              "country" => "US"
            }
          })

          allow(Stripe::Account).to receive(:update_person).and_raise(Stripe::StripeError.new("Stripe error"))

          expect(Rails.logger).to receive(:error).with("Failed to update guardian person for user #{user.id}: Stripe error")
          expect(Bugsnag).to receive(:notify).with(instance_of(Stripe::StripeError))

          expect { described_class.update_guardian_person(user, stripe_account, passphrase) }
            .to raise_error(Stripe::StripeError)
        end
      end

      context "when guardian person does not exist" do
        before do
          allow(Stripe::Account).to receive(:list_persons).and_return({"data" => []})
        end

        it "creates new guardian person" do
          expect(Stripe::Account).to receive(:create_person).with(
            stripe_account.id,
            hash_including(
              first_name: "John",
              last_name: "Doe",
              relationship: {
                representative: true,
                owner: false,
                title: "Legal Guardian"
              }
            )
          )

          described_class.update_guardian_person(user, stripe_account, passphrase)
        end
      end
    end

    describe ".guardian_person_hash" do
      before do
        user_compliance_info.update!(
          guardian_first_name: "John",
          guardian_last_name: "Doe",
          guardian_email: "john@example.com",
          guardian_phone: "+1234567890",
          guardian_street_address: "123 Main St",
          guardian_city: "Anytown",
          guardian_state: "CA",
          guardian_zip_code: "12345",
          guardian_date_of_birth: Date.new(1990, 5, 15),
          guardian_individual_tax_id: "encrypted_tax_id",
          country: "United States"
        )
      end

      it "creates correct guardian person hash" do
        allow(user_compliance_info.guardian_individual_tax_id).to receive(:decrypt).with(passphrase).and_return("123456789")

        result = described_class.guardian_person_hash(user_compliance_info, passphrase)

        expect(result).to include(
          first_name: "John",
          last_name: "Doe",
          email: "john@example.com",
          phone: "+1234567890",
          dob: {
            day: 15,
            month: 5,
            year: 1990
          },
          address: {
            line1: "123 Main St",
            line2: nil,
            city: "Anytown",
            state: "CA",
            postal_code: "12345",
            country: "US"
          },
          id_number: "123456789"
        )
      end

      it "handles missing address gracefully" do
        user_compliance_info.update_column(:country, nil)

        result = described_class.guardian_person_hash(user_compliance_info, passphrase)

        expect(result).not_to have_key(:address)
      end

      it "handles tax ID decryption errors gracefully" do
        allow(user_compliance_info.guardian_individual_tax_id).to receive(:decrypt).with(passphrase)
          .and_raise(StandardError.new("Decryption failed"))

        expect(Rails.logger).to receive(:warn).with("Failed to decrypt guardian tax ID: Decryption failed")

        result = described_class.guardian_person_hash(user_compliance_info, passphrase)

        expect(result).not_to have_key(:id_number)
        expect(result).not_to have_key(:ssn_last_4)
      end

      it "handles SSN last 4 for US" do
        user_compliance_info.update!(guardian_individual_tax_id: "1234")
        allow(user_compliance_info.guardian_individual_tax_id).to receive(:decrypt).with(passphrase).and_return("1234")

        result = described_class.guardian_person_hash(user_compliance_info, passphrase)

        expect(result).to include(ssn_last_4: "1234")
        expect(result).not_to have_key(:id_number)
      end

      it "handles full SSN for US" do
        user_compliance_info.update!(guardian_individual_tax_id: "123456789")
        allow(user_compliance_info.guardian_individual_tax_id).to receive(:decrypt).with(passphrase).and_return("123456789")

        result = described_class.guardian_person_hash(user_compliance_info, passphrase)

        expect(result).to include(id_number: "123456789")
        expect(result).not_to have_key(:ssn_last_4)
      end
    end

    describe ".handle_stripe_event_person_updated" do
      let(:stripe_event) do
        {
          "id" => "evt_123",
          "data" => {
            "object" => stripe_person,
            "previous_attributes" => previous_attributes
          }
        }
      end
      let(:stripe_person) do
        {
          "object" => "person",
          "account" => "acct_123",
          "relationship" => { "representative" => true, "owner" => false },
          "verification" => { "status" => "verified" }
        }
      end
      let(:previous_attributes) { { "verification" => { "status" => "pending" } } }

      before do
        allow(MerchantAccount).to receive(:where).and_return(double("ActiveRecord::Relation", alive: double("ActiveRecord::Relation", charge_processor_alive: double("ActiveRecord::Relation", last: merchant_account))))
        allow(merchant_account).to receive(:user).and_return(user)
      end

      context "when person is a guardian" do
        it "processes guardian verification update" do
          expect(described_class).to receive(:handle_guardian_person_verification_update)
            .with(user, stripe_person, previous_attributes)

          described_class.handle_stripe_event_person_updated(stripe_event)
        end
      end

      context "when person is not a guardian" do
        let(:stripe_person) do
          {
            "object" => "person",
            "account" => "acct_123",
            "relationship" => { "representative" => true, "owner" => true }
          }
        end

        it "does not process guardian verification update" do
          expect(described_class).not_to receive(:handle_guardian_person_verification_update)

          described_class.handle_stripe_event_person_updated(stripe_event)
        end
      end

      context "when user is 18 or older" do
        let(:adult_user) { create(:user) }
        let!(:adult_tos_agreement) { create(:tos_agreement, user: adult_user) }
        let!(:adult_merchant_account) { create(:merchant_account, user: adult_user) }

        before do
          allow(adult_user).to receive(:native_payouts_supported?).and_return(true)
          allow(merchant_account).to receive(:user).and_return(adult_user)
        end

        it "does not process guardian verification update" do
          expect(described_class).not_to receive(:handle_guardian_person_verification_update)

          described_class.handle_stripe_event_person_updated(stripe_event)
        end
      end
    end

    describe ".handle_guardian_person_verification_update" do
      let(:stripe_person) do
        {
          "verification" => { "status" => "verified" }
        }
      end
      let(:stripe_previous_attributes) { { "verification" => { "status" => "pending" } } }

      before do
        allow(user).to receive(:user_compliance_info_requests).and_return(
          double("ActiveRecord::Relation", requested: double("ActiveRecord::Relation",
            where: double("ActiveRecord::Relation", find_each: [])
          ))
        )
        allow(user).to receive(:fetch_or_build_user_compliance_info).and_return(user_compliance_info)
      end

      it "updates guardian verification status to verified" do
        expect(user_compliance_info).to receive(:update!).with(guardian_verification_status: "verified")

        described_class.handle_guardian_person_verification_update(user, stripe_person, stripe_previous_attributes)
      end

      it "updates guardian verification status to pending" do
        stripe_person["verification"]["status"] = "pending"
        stripe_previous_attributes["verification"]["status"] = "verified"

        expect(user_compliance_info).to receive(:update!).with(guardian_verification_status: "pending")

        described_class.handle_guardian_person_verification_update(user, stripe_person, stripe_previous_attributes)
      end

      it "updates guardian verification status to incomplete" do
        stripe_person["verification"]["status"] = "unverified"
        stripe_previous_attributes["verification"]["status"] = "verified"

        expect(user_compliance_info).to receive(:update!).with(guardian_verification_status: "incomplete")

        described_class.handle_guardian_person_verification_update(user, stripe_person, stripe_previous_attributes)
      end

      it "does not update when verification status hasn't changed" do
        stripe_previous_attributes["verification"]["status"] = "verified"

        expect(user_compliance_info).not_to receive(:update!)

        described_class.handle_guardian_person_verification_update(user, stripe_person, stripe_previous_attributes)
      end
    end
  end
end

