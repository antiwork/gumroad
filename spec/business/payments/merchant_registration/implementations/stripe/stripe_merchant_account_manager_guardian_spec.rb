# frozen_string_literal: true

require "spec_helper"

RSpec.describe StripeMerchantAccountManager, "guardian functionality", type: :service do
  let(:user) { create(:user) }
  let(:user_compliance_info) { create(:user_compliance_info, user: user, birthday: 16.years.ago, country: "United States") }
  let(:passphrase) { "test_passphrase" }

  describe ".guardian_person_hash" do
    let(:guardian_compliance_info) do
      create(:user_compliance_info,
        user: user,
        birthday: 16.years.ago,
        guardian_first_name: "Jane",
        guardian_last_name: "Smith",
        guardian_date_of_birth: 45.years.ago,
        guardian_street_address: "456 Oak Ave",
        guardian_city: "Los Angeles",
        guardian_state: "CA",
        guardian_zip_code: "90210",
        guardian_country: "United States",
        guardian_phone: "+1234567890",
        guardian_individual_tax_id: "987654321")
    end

    it "returns guardian person hash for US guardian" do
      result = described_class.guardian_person_hash(guardian_compliance_info, passphrase)

      expect(result[:first_name]).to eq("Jane")
      expect(result[:last_name]).to eq("Smith")
      expect(result[:phone]).to eq("+1234567890")
      expect(result[:dob][:day]).to eq(guardian_compliance_info.guardian_date_of_birth.day)
      expect(result[:dob][:month]).to eq(guardian_compliance_info.guardian_date_of_birth.month)
      expect(result[:dob][:year]).to eq(guardian_compliance_info.guardian_date_of_birth.year)
      expect(result[:address][:line1]).to eq("456 Oak Ave")
      expect(result[:address][:city]).to eq("Los Angeles")
      expect(result[:address][:state]).to eq("CA")
      expect(result[:address][:postal_code]).to eq("90210")
      expect(result[:address][:country]).to eq("US")
      expect(result[:id_number]).to eq("987654321")
    end

    it "handles SSN last 4 for US guardians" do
      guardian_compliance_info.update!(guardian_individual_tax_id: "1234")
      result = described_class.guardian_person_hash(guardian_compliance_info, passphrase)

      expect(result[:ssn_last_4]).to eq("1234")
      expect(result[:id_number]).to be_nil
    end

    it "handles non-US guardians" do
      guardian_compliance_info.update!(guardian_country: "Canada")
      result = described_class.guardian_person_hash(guardian_compliance_info, passphrase)

      expect(result[:address][:country]).to eq("CA")
      expect(result[:id_number]).to eq("987654321")
      expect(result[:ssn_last_4]).to be_nil
    end

    it "returns nil when user is not under 18" do
      guardian_compliance_info.update!(birthday: 20.years.ago)
      result = described_class.guardian_person_hash(guardian_compliance_info, passphrase)

      expect(result).to be_nil
    end

    it "handles missing guardian information gracefully" do
      guardian_compliance_info.update!(
        guardian_first_name: nil,
        guardian_last_name: nil,
        guardian_country: nil,
        guardian_individual_tax_id: nil
      )

      result = described_class.guardian_person_hash(guardian_compliance_info, passphrase)

      expect(result[:first_name]).to be_nil
      expect(result[:last_name]).to be_nil
      expect(result[:address]).to be_nil
      expect(result[:id_number]).to be_nil
    end
  end

  describe "guardian person creation in account creation" do
    let(:bank_account) { create(:bank_account, user: user) }
    let(:tos_agreement) { create(:tos_agreement, user: user) }

    before do
      allow(Stripe::Account).to receive(:create).and_return(double(id: "acct_test123"))
      allow(Stripe::Account).to receive(:create_person).and_return(double(id: "person_test123"))
      allow(Stripe::Account).to receive(:list_persons).and_return(double(data: []))
    end

    context "when user is under 18 and guardian verification is required" do
      before do
        user_compliance_info.update!(
          guardian_first_name: "Jane",
          guardian_last_name: "Smith",
          guardian_date_of_birth: 45.years.ago,
          guardian_street_address: "456 Oak Ave",
          guardian_city: "Los Angeles",
          guardian_state: "CA",
          guardian_zip_code: "90210",
          guardian_country: "United States",
          guardian_phone: "+1234567890"
        )
        allow(user_compliance_info).to receive(:guardian_verification_required?).and_return(true)
      end

      it "creates guardian person in Stripe account" do
        expect(Stripe::Account).to receive(:create_person).with(
          "acct_test123",
          hash_including(
            first_name: "Jane",
            last_name: "Smith",
            relationship: hash_including(
              representative: true,
              owner: false,
              title: "Legal Guardian"
            )
          )
        )

        described_class.create_account(user, passphrase: passphrase, from_admin: false)
      end
    end

    context "when user is 18 or older" do
      before do
        user_compliance_info.update!(birthday: 20.years.ago)
      end

      it "does not create guardian person" do
        expect(Stripe::Account).not_to receive(:create_person)

        described_class.create_account(user, passphrase: passphrase, from_admin: false)
      end
    end

    context "when guardian verification is not required" do
      before do
        allow(user_compliance_info).to receive(:guardian_verification_required?).and_return(false)
      end

      it "does not create guardian person" do
        expect(Stripe::Account).not_to receive(:create_person)

        described_class.create_account(user, passphrase: passphrase, from_admin: false)
      end
    end
  end
end
