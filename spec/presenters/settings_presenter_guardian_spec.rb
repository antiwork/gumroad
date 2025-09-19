# frozen_string_literal: true

require "spec_helper"

describe SettingsPresenter, "guardian verification" do
  let(:user) { create(:user) }
  let(:user_compliance_info) { create(:user_compliance_info, user: user) }
  let(:presenter) { described_class.new(pundit_user: user) }

  before do
    user_compliance_info.update!(
      birthday: 17.years.ago,
      guardian_first_name: "John",
      guardian_last_name: "Doe",
      guardian_email: "guardian@example.com",
      guardian_phone: "555-1234",
      guardian_street_address: "123 Main St",
      guardian_city: "Anytown",
      guardian_state: "CA",
      guardian_zip_code: "12345",
      guardian_date_of_birth: Date.new(1980, 6, 15),
      guardian_stripe_tos_accepted: true,
      guardian_stripe_processing_tos_accepted: true
    )
  end

  describe "#payments_props" do
    let(:props) { presenter.payments_props(remote_ip: "127.0.0.1") }

    it "includes guardian information in compliance_info" do
      expect(props[:compliance_info]).to include(
        guardian_first_name: "John",
        guardian_last_name: "Doe",
        guardian_email: "guardian@example.com",
        guardian_phone: "555-1234",
        guardian_street_address: "123 Main St",
        guardian_city: "Anytown",
        guardian_state: "CA",
        guardian_zip_code: "12345",
        guardian_dob_month: 6,
        guardian_dob_day: 15,
        guardian_dob_year: 1980,
        guardian_verification_status: "pending"
      )
    end

    it "includes guardian tax ID placeholder when present" do
      user_compliance_info.update!(guardian_individual_tax_id: "encrypted_tax_id")

      expect(props[:compliance_info]).to include(
        guardian_individual_tax_id: "***"
      )
    end

    it "includes nil for guardian tax ID when not present" do
      user_compliance_info.update!(guardian_individual_tax_id: nil)

      expect(props[:compliance_info]).to include(
        guardian_individual_tax_id: nil
      )
    end

    it "includes tax ID entered flags" do
      user_compliance_info.update!(
        individual_tax_id: "encrypted_individual_tax_id",
        business_tax_id: "encrypted_business_tax_id"
      )

      expect(props[:compliance_info]).to include(
        individual_tax_id_entered: true,
        business_tax_id_entered: true
      )
    end

    it "includes false for tax ID entered flags when not present" do
      user_compliance_info.update!(
        individual_tax_id: nil,
        business_tax_id: nil
      )

      expect(props[:compliance_info]).to include(
        individual_tax_id_entered: false,
        business_tax_id_entered: false
      )
    end

    context "when user is 18 or older" do
      before { user_compliance_info.update!(birthday: 19.years.ago) }

      it "includes guardian verification status as not_required" do
        expect(props[:compliance_info]).to include(
          guardian_verification_status: "not_required"
        )
      end

      it "includes default values for guardian date fields" do
        expect(props[:compliance_info]).to include(
          guardian_dob_month: 0,
          guardian_dob_day: 0,
          guardian_dob_year: 0
        )
      end
    end

    context "when guardian information is incomplete" do
      before do
        user_compliance_info.update!(
          guardian_first_name: "John",
          guardian_last_name: "Doe"
          # Missing other required fields
        )
      end

      it "includes guardian verification status as incomplete" do
        expect(props[:compliance_info]).to include(
          guardian_verification_status: "incomplete"
        )
      end
    end

    context "when guardian information is verified" do
      before do
        user_compliance_info.update!(
          guardian_verification_status: "verified"
        )
      end

      it "includes guardian verification status as verified" do
        expect(props[:compliance_info]).to include(
          guardian_verification_status: "verified"
        )
      end
    end

    context "when guardian date of birth is nil" do
      before do
        user_compliance_info.update!(
          guardian_date_of_birth: nil
        )
      end

      it "includes default values for guardian date fields" do
        expect(props[:compliance_info]).to include(
          guardian_dob_month: 0,
          guardian_dob_day: 0,
          guardian_dob_year: 0
        )
      end
    end

    context "when guardian information is cleared (age-out)" do
      before do
        user_compliance_info.update!(
          birthday: 19.years.ago,
          guardian_first_name: nil,
          guardian_last_name: nil,
          guardian_email: nil,
          guardian_phone: nil,
          guardian_street_address: nil,
          guardian_city: nil,
          guardian_state: nil,
          guardian_zip_code: nil,
          guardian_date_of_birth: nil,
          guardian_verification_status: "not_required"
        )
      end

      it "includes cleared guardian information" do
        expect(props[:compliance_info]).to include(
          guardian_first_name: nil,
          guardian_last_name: nil,
          guardian_email: nil,
          guardian_phone: nil,
          guardian_street_address: nil,
          guardian_city: nil,
          guardian_state: nil,
          guardian_zip_code: nil,
          guardian_dob_month: 0,
          guardian_dob_day: 0,
          guardian_dob_year: 0,
          guardian_verification_status: "not_required"
        )
      end
    end
  end

  describe "encrypted field handling" do
    let(:props) { presenter.payments_props(remote_ip: "127.0.0.1") }

    context "with encrypted guardian tax ID" do
      before do
        # Simulate encrypted binary data
        user_compliance_info.update_column(:guardian_individual_tax_id, "encrypted_binary_data")
      end

      it "returns placeholder for guardian tax ID" do
        expect(props[:compliance_info]).to include(
          guardian_individual_tax_id: "***"
        )
      end
    end

    context "with encrypted individual tax ID" do
      before do
        user_compliance_info.update_column(:individual_tax_id, "encrypted_binary_data")
      end

      it "returns true for individual tax ID entered flag" do
        expect(props[:compliance_info]).to include(
          individual_tax_id_entered: true
        )
      end
    end

    context "with encrypted business tax ID" do
      before do
        user_compliance_info.update_column(:business_tax_id, "encrypted_binary_data")
      end

      it "returns true for business tax ID entered flag" do
        expect(props[:compliance_info]).to include(
          business_tax_id_entered: true
        )
      end
    end
  end

  describe "guardian verification status handling" do
    let(:props) { presenter.payments_props(remote_ip: "127.0.0.1") }

    context "when guardian verification status is pending" do
      before do
        user_compliance_info.update_column(:guardian_verification_status, "pending")
      end

      it "returns pending status" do
        expect(props[:compliance_info]).to include(
          guardian_verification_status: "pending"
        )
      end
    end

    context "when guardian verification status is verified" do
      before do
        user_compliance_info.update_column(:guardian_verification_status, "verified")
      end

      it "returns verified status" do
        expect(props[:compliance_info]).to include(
          guardian_verification_status: "verified"
        )
      end
    end

    context "when guardian verification status is incomplete" do
      before do
        user_compliance_info.update_column(:guardian_verification_status, "incomplete")
      end

      it "returns incomplete status" do
        expect(props[:compliance_info]).to include(
          guardian_verification_status: "incomplete"
        )
      end
    end

    context "when guardian verification status is not_required" do
      before do
        user_compliance_info.update_column(:guardian_verification_status, "not_required")
      end

      it "returns not_required status" do
        expect(props[:compliance_info]).to include(
          guardian_verification_status: "not_required"
        )
      end
    end
  end
end
