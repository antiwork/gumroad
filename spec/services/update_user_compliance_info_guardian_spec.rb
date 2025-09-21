# frozen_string_literal: true

require "spec_helper"

RSpec.describe UpdateUserComplianceInfo, type: :service do
  describe "guardian functionality" do
    let(:user) { create(:user) }
    let!(:user_compliance_info) do
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
        guardian_tax_id: "123456789",
        guardian_stripe_tos_accepted: true,
        guardian_stripe_processing_tos_accepted: true,
        country: "United States"
      )
    end
    let(:service) { described_class.new(compliance_params: params, user: user) }

    before do
      allow(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info).and_return(true)
    end

    context "when updating guardian fields" do
      let(:params) do
        {
          guardian_first_name: "Jane",
          guardian_last_name: "Smith",
          guardian_email: "jane@example.com",
          guardian_phone: "+1987654321",
          guardian_street_address: "456 Oak Ave",
          guardian_city: "Springfield",
          guardian_state: "NY",
          guardian_zip_code: "54321",
          guardian_dob_year: 1980,
          guardian_dob_month: 6,
          guardian_dob_day: 20,
          guardian_tax_id: "987654321",
          guardian_stripe_tos_accepted: true,
          guardian_stripe_processing_tos_accepted: true
        }
      end

      it "updates guardian fields correctly" do
        result = service.process

        expect(result[:success]).to be true

        new_compliance_info = user.fetch_or_build_user_compliance_info
        expect(new_compliance_info.guardian_first_name).to eq("Jane")
        expect(new_compliance_info.guardian_last_name).to eq("Smith")
        expect(new_compliance_info.guardian_email).to eq("jane@example.com")
        expect(new_compliance_info.guardian_phone).to eq("+1987654321")
        expect(new_compliance_info.guardian_street_address).to eq("456 Oak Ave")
        expect(new_compliance_info.guardian_city).to eq("Springfield")
        expect(new_compliance_info.guardian_state).to eq("NY")
        expect(new_compliance_info.guardian_zip_code).to eq("54321")
        expect(new_compliance_info.guardian_date_of_birth).to eq(Date.new(1980, 6, 20))
        expect(new_compliance_info.guardian_tax_id.decrypt("1234")).to eq("987654321")
        expect(new_compliance_info.guardian_stripe_tos_accepted).to be true
        expect(new_compliance_info.guardian_stripe_processing_tos_accepted).to be true
      end

      it "calls StripeMerchantAccountManager.handle_new_user_compliance_info" do
        expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)

        service.process
      end
    end

    context "when updating only some guardian fields" do
      let(:params) do
        {
          guardian_first_name: "Updated First Name",
          guardian_email: "updated@example.com"
        }
      end

      it "updates only the provided guardian fields" do
        result = service.process

        expect(result[:success]).to be true

        new_compliance_info = user.fetch_or_build_user_compliance_info
        expect(new_compliance_info.guardian_first_name).to eq("Updated First Name")
        expect(new_compliance_info.guardian_email).to eq("updated@example.com")
        # Other guardian fields should remain unchanged
        expect(new_compliance_info.guardian_last_name).to eq("Doe")
        expect(new_compliance_info.guardian_phone).to eq("+1234567890")
      end
    end

    context "when guardian date of birth fields are incomplete" do
      let(:params) do
        {
          guardian_dob_year: 1980,
          guardian_dob_month: 6
          # guardian_dob_day is missing
        }
      end

      it "does not update guardian_date_of_birth when year is 0 or missing" do
        params[:guardian_dob_year] = 0

        result = service.process

        expect(result[:success]).to be true

        new_compliance_info = user.fetch_or_build_user_compliance_info
        expect(new_compliance_info.guardian_date_of_birth).to eq(40.years.ago.to_date)
      end

      it "does not update guardian_date_of_birth when year is missing" do
        params.delete(:guardian_dob_year)

        result = service.process

        expect(result[:success]).to be true

        new_compliance_info = user.fetch_or_build_user_compliance_info
        expect(new_compliance_info.guardian_date_of_birth).to eq(40.years.ago.to_date)
      end
    end

    context "when guardian tax ID is provided" do
      let(:params) do
        {
          guardian_tax_id: "555666777"
        }
      end

      it "updates guardian_tax_id correctly" do
        result = service.process

        expect(result[:success]).to be true

        new_compliance_info = user.fetch_or_build_user_compliance_info
        expect(new_compliance_info.guardian_tax_id.decrypt("1234")).to eq("555666777")
      end
    end

    context "when guardian Stripe TOS fields are provided" do
      let(:params) do
        {
          guardian_stripe_tos_accepted: false,
          guardian_stripe_processing_tos_accepted: false
        }
      end

      it "updates guardian TOS fields correctly" do
        result = service.process

        expect(result[:success]).to be true

        new_compliance_info = user.fetch_or_build_user_compliance_info
        expect(new_compliance_info.guardian_stripe_tos_accepted).to be false
        expect(new_compliance_info.guardian_stripe_processing_tos_accepted).to be false
      end
    end

    context "when no guardian fields are provided" do
      let(:params) do
        {
          first_name: "Updated First Name"
        }
      end

      it "does not modify guardian fields" do
        result = service.process

        expect(result[:success]).to be true

        new_compliance_info = user.fetch_or_build_user_compliance_info
        expect(new_compliance_info.guardian_first_name).to eq("John")
        expect(new_compliance_info.guardian_last_name).to eq("Doe")
        expect(new_compliance_info.guardian_email).to eq("john@example.com")
      end
    end

    context "when StripeMerchantAccountManager raises an error" do
      let(:params) do
        {
          guardian_first_name: "Jane"
        }
      end

      before do
        allow(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)
          .and_raise(Stripe::InvalidRequestError.new("Invalid request", "param"))
      end

      it "returns an error result" do
        result = service.process

        expect(result[:success]).to be false
        expect(result[:error_message]).to include("Compliance info update failed with this error: Invalid request")
        expect(result[:error_code]).to eq("stripe_error")
      end
    end

    context "when compliance info validation fails" do
      let(:params) do
        {
          guardian_first_name: "Jane",
          dob_year: 2013,  # This should fail minimum age validation (12 years old)
          dob_month: 1,
          dob_day: 1
        }
      end

      it "returns an error result" do
        result = service.process

        expect(result[:success]).to be false
        expect(result[:error_message]).to include("You must be 13 years old to use Gumroad")
      end
    end

    context "when no compliance params are provided" do
      let(:params) { {} }

      it "returns success without processing" do
        result = service.process

        expect(result[:success]).to be true
        expect(StripeMerchantAccountManager).not_to receive(:handle_new_user_compliance_info)
      end
    end

    context "when compliance params are nil" do
      let(:params) { nil }

      it "returns success without processing" do
        service = described_class.new(compliance_params: params, user: user)
        result = service.process

        expect(result[:success]).to be true
        expect(StripeMerchantAccountManager).not_to receive(:handle_new_user_compliance_info)
      end
    end
  end
end
