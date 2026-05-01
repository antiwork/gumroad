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
