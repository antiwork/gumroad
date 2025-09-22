# frozen_string_literal: true

require "spec_helper"

describe StripeMerchantAccountManager, :guardian_functionality do
  let(:user) { create(:user) }
  let(:passphrase) { "test_passphrase" }
  let(:user_compliance_info) { create(:user_compliance_info, user: user) }

  describe ".create_account with guardian information" do
    context "when user is under 18 with complete guardian information" do
      let(:user_compliance_info) do
        create(:user_compliance_info,
          user: user,
          birthday: 15.years.ago,
          guardian_first_name: "John",
          guardian_last_name: "Doe",
          guardian_email: "guardian@example.com",
          guardian_phone: "+1234567890",
          guardian_street_address: "123 Main St",
          guardian_city: "Anytown",
          guardian_state: "CA",
          guardian_zip_code: "12345",
          guardian_date_of_birth: 40.years.ago,
          guardian_tax_id: "123456789",
          guardian_verified: false,
          guardian_stripe_tos_accepted: true,
          guardian_stripe_processing_tos_accepted: true
        )
      end

      let(:bank_account) { create(:bank_account, user: user) }
      let(:tos_agreement) { create(:tos_agreement, user: user) }

      before do
        allow(user).to receive(:native_payouts_supported?).and_return(true)
        allow(user).to receive(:active_bank_account).and_return(bank_account)
        allow(user).to receive(:tos_agreements).and_return([tos_agreement])
        allow(user).to receive(:alive_user_compliance_info).and_return(user_compliance_info)
      end

      it "creates both guardian and minor persons in Stripe" do
        expect(Stripe::Account).to receive(:create).and_return(double(id: "acct_test"))
        expect(Stripe::Account).to receive(:create_person).twice

        described_class.create_account(user, passphrase: passphrase)
      end

      it "validates guardian information completeness before creating account" do
        incomplete_user_compliance_info = create(:user_compliance_info,
          user: user,
          birthday: 15.years.ago,
          guardian_first_name: "John",
          guardian_last_name: "Doe"
          # Missing other guardian fields
        )

        allow(user).to receive(:alive_user_compliance_info).and_return(incomplete_user_compliance_info)

        expect {
          described_class.create_account(user, passphrase: passphrase)
        }.to raise_error(MerchantRegistrationUserNotReadyError, /guardian information incomplete for minor/)
      end
    end

    context "when user is 18 or older" do
      let(:user_compliance_info) do
        create(:user_compliance_info,
          user: user,
          birthday: 20.years.ago
        )
      end

      let(:bank_account) { create(:bank_account, user: user) }
      let(:tos_agreement) { create(:tos_agreement, user: user) }

      before do
        allow(user).to receive(:native_payouts_supported?).and_return(true)
        allow(user).to receive(:active_bank_account).and_return(bank_account)
        allow(user).to receive(:tos_agreements).and_return([tos_agreement])
        allow(user).to receive(:alive_user_compliance_info).and_return(user_compliance_info)
      end

      it "does not create guardian persons" do
        expect(Stripe::Account).to receive(:create).and_return(double(id: "acct_test"))
        expect(Stripe::Account).not_to receive(:create_person)

        described_class.create_account(user, passphrase: passphrase)
      end
    end
  end

  describe ".guardian_person_hash" do
    let(:user_compliance_info) do
      create(:user_compliance_info,
        user: user,
        birthday: 15.years.ago,
        guardian_first_name: "John",
        guardian_last_name: "Doe",
        guardian_email: "guardian@example.com",
        guardian_phone: "+1234567890",
        guardian_street_address: "123 Main St",
        guardian_city: "Anytown",
        guardian_state: "CA",
        guardian_zip_code: "12345",
        guardian_date_of_birth: 40.years.ago,
        guardian_tax_id: "123456789"
      )
    end

    it "returns nil for users 18 or older" do
      user_compliance_info.update!(birthday: 20.years.ago)
      result = described_class.send(:guardian_person_hash, user_compliance_info, passphrase)
      expect(result).to be_nil
    end

    it "returns guardian information hash for users under 18" do
      result = described_class.send(:guardian_person_hash, user_compliance_info, passphrase)

      expect(result[:first_name]).to eq("John")
      expect(result[:last_name]).to eq("Doe")
      expect(result[:email]).to eq("guardian@example.com")
      expect(result[:phone]).to eq("+1234567890")
      expect(result[:dob][:day]).to eq(40.years.ago.day)
      expect(result[:dob][:month]).to eq(40.years.ago.month)
      expect(result[:dob][:year]).to eq(40.years.ago.year)
      expect(result[:address][:line1]).to eq("123 Main St")
      expect(result[:address][:city]).to eq("Anytown")
      expect(result[:address][:state]).to eq("CA")
      expect(result[:address][:postal_code]).to eq("12345")
      expect(result[:address][:country]).to eq("US")
    end

    it "includes tax ID information for non-US guardians" do
      user_compliance_info.update!(country: "CA")
      result = described_class.send(:guardian_person_hash, user_compliance_info, passphrase)

      expect(result[:id_number]).to eq("123456789")
    end

    it "includes SSN last 4 for US guardians with 4-digit tax ID" do
      user_compliance_info.update!(guardian_tax_id: "1234")
      result = described_class.send(:guardian_person_hash, user_compliance_info, passphrase)

      expect(result[:ssn_last_4]).to eq("1234")
    end

    it "handles missing guardian tax ID gracefully" do
      user_compliance_info.update!(guardian_tax_id: nil)
      result = described_class.send(:guardian_person_hash, user_compliance_info, passphrase)

      expect(result[:id_number]).to be_nil
      expect(result[:ssn_last_4]).to be_nil
    end
  end

  describe ".update_person with guardian information" do
    let(:stripe_account) { double(id: "acct_test") }
    let(:stripe_persons) { [double(id: "person_guardian"), double(id: "person_minor")] }
    let(:user_compliance_info) do
      create(:user_compliance_info,
        user: user,
        birthday: 15.years.ago,
        guardian_first_name: "John",
        guardian_last_name: "Doe",
        guardian_email: "guardian@example.com",
        guardian_phone: "+1234567890",
        guardian_street_address: "123 Main St",
        guardian_city: "Anytown",
        guardian_state: "CA",
        guardian_zip_code: "12345",
        guardian_date_of_birth: 40.years.ago,
        guardian_tax_id: "123456789"
      )
    end

    before do
      allow(user).to receive(:alive_user_compliance_info).and_return(user_compliance_info)
      allow(Stripe::Account).to receive(:list_persons).with(stripe_account.id).and_return(double(data: stripe_persons))
    end

    context "when user is under 18" do
      it "updates both guardian and minor persons" do
        expect(Stripe::Account).to receive(:update_person).with(stripe_account.id, "person_guardian", anything).twice
        expect(Stripe::Account).to receive(:update_person).with(stripe_account.id, "person_minor", anything).twice

        described_class.update_person(user, stripe_account, nil, passphrase)
      end

      it "handles missing last compliance info gracefully" do
        expect(Stripe::Account).to receive(:update_person).with(stripe_account.id, "person_guardian", anything).twice
        expect(Stripe::Account).to receive(:update_person).with(stripe_account.id, "person_minor", anything).twice

        described_class.update_person(user, stripe_account, nil, passphrase)
      end
    end

    context "when user is 18 or older" do
      before do
        user_compliance_info.update!(birthday: 20.years.ago)
      end

      it "updates only the minor person" do
        expect(Stripe::Account).to receive(:update_person).with(stripe_account.id, "person_minor", anything).once

        described_class.update_person(user, stripe_account, nil, passphrase)
      end
    end
  end

  describe ".update_guardian_and_minor_persons" do
    let(:stripe_account) { double(id: "acct_test") }
    let(:stripe_persons) { [double(id: "person_guardian"), double(id: "person_minor")] }
    let(:user_compliance_info) do
      create(:user_compliance_info,
        user: user,
        birthday: 15.years.ago,
        guardian_first_name: "John",
        guardian_last_name: "Doe",
        guardian_email: "guardian@example.com",
        guardian_phone: "+1234567890",
        guardian_street_address: "123 Main St",
        guardian_city: "Anytown",
        guardian_state: "CA",
        guardian_zip_code: "12345",
        guardian_date_of_birth: 40.years.ago,
        guardian_tax_id: "123456789"
      )
    end

    it "updates guardian person with correct attributes" do
      expect(Stripe::Account).to receive(:update_person).with(stripe_account.id, "person_guardian", hash_including(
        first_name: "John",
        last_name: "Doe",
        email: "guardian@example.com",
        phone: "+1234567890"
      )).once

      expect(Stripe::Account).to receive(:update_person).with(stripe_account.id, "person_minor", anything).once

      described_class.send(:update_guardian_and_minor_persons, user, stripe_account, stripe_persons, nil, user_compliance_info, passphrase)
    end

    it "updates minor person with correct attributes" do
      expect(Stripe::Account).to receive(:update_person).with(stripe_account.id, "person_guardian", anything).once

      expect(Stripe::Account).to receive(:update_person).with(stripe_account.id, "person_minor", hash_including(
        relationship: { representative: true, owner: true }
      )).once

      described_class.send(:update_guardian_and_minor_persons, user, stripe_account, stripe_persons, nil, user_compliance_info, passphrase)
    end

    it "handles missing persons gracefully" do
      empty_persons = []

      expect(Stripe::Account).not_to receive(:update_person)

      described_class.send(:update_guardian_and_minor_persons, user, stripe_account, empty_persons, nil, user_compliance_info, passphrase)
    end
  end

  describe "guardian verification tracking" do
    let(:user_compliance_info) do
      create(:user_compliance_info,
        user: user,
        birthday: 15.years.ago,
        guardian_first_name: "John",
        guardian_last_name: "Doe",
        guardian_email: "john@example.com",
        guardian_phone: "+1234567890",
        guardian_street_address: "123 Main St",
        guardian_city: "Anytown",
        guardian_state: "CA",
        guardian_zip_code: "12345",
        guardian_date_of_birth: 40.years.ago,
        guardian_tax_id: "123456789",
        guardian_verified: false,
        guardian_stripe_tos_accepted: true,
        guardian_stripe_processing_tos_accepted: true
      )
    end

    it "marks guardian as verified after successful Stripe account creation" do
      expect(Stripe::Account).to receive(:create).and_return(double(id: "acct_test"))
      expect(Stripe::Account).to receive(:create_person).twice

      described_class.create_account(user, passphrase: passphrase)

      # Verify guardian is marked as verified
      updated_compliance_info = user.reload.alive_user_compliance_info
      expect(updated_compliance_info.guardian_verified).to be true
    end
  end
end
