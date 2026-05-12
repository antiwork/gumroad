# frozen_string_literal: true

require "spec_helper"

describe UpdateUserComplianceInfo do
  describe "#process" do
    let(:user) { create(:user) }

    context "when individual_tax_id exceeds maximum length" do
      it "returns an error without attempting RSA encryption" do
        oversized_tax_id = "1" * 201
        params = ActionController::Parameters.new(individual_tax_id: oversized_tax_id)

        result = described_class.new(compliance_params: params, user: user).process

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("Individual tax id is too long")
      end
    end

    context "when business_tax_id exceeds maximum length" do
      it "returns an error without attempting RSA encryption" do
        oversized_tax_id = "1" * 201
        params = ActionController::Parameters.new(business_tax_id: oversized_tax_id)

        result = described_class.new(compliance_params: params, user: user).process

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("Business tax id is too long")
      end
    end

    context "when ssn_last_four exceeds maximum length" do
      it "returns an error without attempting RSA encryption" do
        oversized_ssn = "1" * 201
        params = ActionController::Parameters.new(ssn_last_four: oversized_ssn)

        result = described_class.new(compliance_params: params, user: user).process

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("Individual tax id is too long")
      end
    end

    context "when individual_tax_id is valid but ssn_last_four exceeds maximum length" do
      it "returns an error before assigning either value" do
        params = ActionController::Parameters.new(individual_tax_id: "123456789", ssn_last_four: "1" * 201)

        result = described_class.new(compliance_params: params, user: user).process

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("Individual tax id is too long")
      end
    end

    context "when submitted compliance values match the current compliance info" do
      let!(:compliance_info) { create(:user_compliance_info, user:) }

      it "returns success without creating a new compliance info row or submitting it to Stripe" do
        request = create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::Address::STREET)
        params = ActionController::Parameters.new(
          first_name: compliance_info.first_name,
          last_name: compliance_info.last_name,
          street_address: compliance_info.street_address,
          city: compliance_info.city,
          state: compliance_info.state,
          zip_code: compliance_info.zip_code,
          country: compliance_info.country_code,
          business_country: compliance_info.country_code,
          is_business: false,
          ssn_last_four: "000000000",
          dob_month: compliance_info.birthday.month.to_s,
          dob_day: compliance_info.birthday.day.to_s,
          dob_year: compliance_info.birthday.year.to_s,
          phone: compliance_info.phone,
        )

        expect(StripeMerchantAccountManager).not_to receive(:handle_new_user_compliance_info)

        result = nil
        expect do
          result = described_class.new(compliance_params: params, user: user).process
        end.not_to change { UserComplianceInfo.count }

        expect(result[:success]).to be true
        expect(user.reload.alive_user_compliance_info.id).to eq(compliance_info.id)
        expect(request.reload.state).to eq("provided")
      end
    end

    context "when submitted compliance values change the current compliance info" do
      let!(:compliance_info) { create(:user_compliance_info, user:) }

      it "creates a new compliance info row and submits it to Stripe" do
        params = ActionController::Parameters.new(first_name: "Morgan")

        expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info) do |new_compliance_info|
          expect(new_compliance_info.first_name).to eq("Morgan")
        end

        result = nil
        expect do
          result = described_class.new(compliance_params: params, user: user).process
        end.to change { UserComplianceInfo.count }.by(1)

        expect(result[:success]).to be true
        expect(user.reload.alive_user_compliance_info.first_name).to eq("Morgan")
        expect(user.alive_user_compliance_info.id).not_to eq(compliance_info.id)
      end
    end

    context "with a US business that already has a 9-digit business_tax_id saved" do
      let(:us_business_user) do
        create(:user).tap { |u| create(:user_compliance_info_business, user: u) }
      end

      it "accepts a non-tax-id field update without re-submitting business_tax_id" do
        params = ActionController::Parameters.new(
          is_business: true,
          business_street_address: "456 Updated Street",
        )

        result = described_class.new(compliance_params: params, user: us_business_user).process

        expect(result[:success]).to be true
        expect(us_business_user.alive_user_compliance_info.business_street_address).to eq("456 Updated Street")
      end

      it "rejects a too-short business_tax_id submitted in the same request" do
        params = ActionController::Parameters.new(
          is_business: true,
          business_tax_id: "12345",
        )

        result = described_class.new(compliance_params: params, user: us_business_user).process

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("US business tax IDs (EIN) must have 9 digits.")
      end

      it "accepts a 9-digit business_tax_id submitted with formatting" do
        params = ActionController::Parameters.new(
          is_business: true,
          business_tax_id: "12-3456789",
        )

        result = described_class.new(compliance_params: params, user: us_business_user).process

        expect(result[:success]).to be true
      end
    end
  end
end
