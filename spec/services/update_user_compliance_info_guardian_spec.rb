# frozen_string_literal: true

require "spec_helper"

RSpec.describe UpdateUserComplianceInfo, "guardian fields", type: :service do
  let(:user) { create(:user) }
  let(:user_compliance_info) { create(:user_compliance_info, user: user) }
  let(:service) { described_class.new(compliance_params: params, user: user) }

  describe "guardian field updates" do
    let(:params) do
      {
        guardian_first_name: "John",
        guardian_last_name: "Doe",
        guardian_dob_year: "1980",
        guardian_dob_month: "5",
        guardian_dob_day: "15",
        guardian_street_address: "123 Main St",
        guardian_city: "New York",
        guardian_state: "NY",
        guardian_zip_code: "10001",
        guardian_country: "US",
        guardian_phone: "+1234567890",
        guardian_individual_tax_id: "123456789",
        guardian_stripe_processing_tos_accepted: true,
        guardian_stripe_tos_accepted: true
      }
    end

    it "updates guardian first name" do
      result = service.process
      expect(result[:success]).to be true
      expect(user_compliance_info.reload.guardian_first_name).to eq("John")
    end

    it "updates guardian last name" do
      result = service.process
      expect(result[:success]).to be true
      expect(user_compliance_info.reload.guardian_last_name).to eq("Doe")
    end

    it "updates guardian date of birth" do
      result = service.process
      expect(result[:success]).to be true
      expect(user_compliance_info.reload.guardian_date_of_birth).to eq(Date.new(1980, 5, 15))
    end

    it "updates guardian name" do
      result = service.process
      expect(result[:success]).to be true
      expect(user_compliance_info.reload.guardian_first_name).to eq("John")
    end

    it "updates guardian address fields" do
      result = service.process
      expect(result[:success]).to be true
      compliance_info = user_compliance_info.reload
      expect(compliance_info.guardian_street_address).to eq("123 Main St")
      expect(compliance_info.guardian_city).to eq("New York")
      expect(compliance_info.guardian_state).to eq("NY")
      expect(compliance_info.guardian_zip_code).to eq("10001")
    end

    it "updates guardian country" do
      result = service.process
      expect(result[:success]).to be true
      expect(user_compliance_info.reload.guardian_country).to eq("United States")
    end

    it "updates guardian phone" do
      result = service.process
      expect(result[:success]).to be true
      expect(user_compliance_info.reload.guardian_phone).to eq("+1234567890")
    end

    it "updates guardian tax ID" do
      result = service.process
      expect(result[:success]).to be true
      expect(user_compliance_info.reload.guardian_individual_tax_id).to be_present
    end

    it "updates guardian TOS acceptance flags" do
      result = service.process
      expect(result[:success]).to be true
      compliance_info = user_compliance_info.reload
      expect(compliance_info.guardian_stripe_processing_tos_accepted).to be true
      expect(compliance_info.guardian_stripe_tos_accepted).to be true
    end
  end

  describe "guardian date of birth handling" do
    context "with invalid date" do
      let(:params) do
        {
          guardian_dob_year: "invalid",
          guardian_dob_month: "13",
          guardian_dob_day: "32"
        }
      end

      it "does not update guardian date of birth" do
        result = service.process
        expect(result[:success]).to be true
        expect(user_compliance_info.reload.guardian_date_of_birth).to be_nil
      end
    end

    context "with zero year" do
      let(:params) do
        {
          guardian_dob_year: "0",
          guardian_dob_month: "5",
          guardian_dob_day: "15"
        }
      end

      it "does not update guardian date of birth" do
        result = service.process
        expect(result[:success]).to be true
        expect(user_compliance_info.reload.guardian_date_of_birth).to be_nil
      end
    end
  end

  describe "guardian TOS acceptance handling" do
    context "with false values" do
      let(:params) do
        {
          guardian_stripe_processing_tos_accepted: false,
          guardian_stripe_tos_accepted: false
        }
      end

      it "updates TOS flags to false" do
        result = service.process
        expect(result[:success]).to be true
        compliance_info = user_compliance_info.reload
        expect(compliance_info.guardian_stripe_processing_tos_accepted).to be false
        expect(compliance_info.guardian_stripe_tos_accepted).to be false
      end
    end

    context "with nil values" do
      let(:params) do
        {
          guardian_stripe_processing_tos_accepted: nil,
          guardian_stripe_tos_accepted: nil
        }
      end

      it "does not update TOS flags" do
        user_compliance_info.update!(
          guardian_stripe_processing_tos_accepted: true,
          guardian_stripe_tos_accepted: true
        )

        result = service.process
        expect(result[:success]).to be true
        compliance_info = user_compliance_info.reload
        expect(compliance_info.guardian_stripe_processing_tos_accepted).to be true
        expect(compliance_info.guardian_stripe_tos_accepted).to be true
      end
    end
  end

  describe "partial updates" do
    let(:params) { { guardian_first_name: "Jane" } }

    it "only updates provided fields" do
      user_compliance_info.update!(guardian_last_name: "Smith")

      result = service.process
      expect(result[:success]).to be true
      compliance_info = user_compliance_info.reload
      expect(compliance_info.guardian_first_name).to eq("Jane")
      expect(compliance_info.guardian_last_name).to eq("Smith") # unchanged
    end
  end
end
