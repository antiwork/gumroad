# frozen_string_literal: true

require "spec_helper"

RSpec.describe UserComplianceInfoFields::Guardian, type: :module do
  describe "Guardian field constants" do
    it "defines all required guardian personal fields" do
      expect(UserComplianceInfoFields::Guardian::FIRST_NAME).to eq("guardian_first_name")
      expect(UserComplianceInfoFields::Guardian::LAST_NAME).to eq("guardian_last_name")
      expect(UserComplianceInfoFields::Guardian::EMAIL).to eq("guardian_email")
      expect(UserComplianceInfoFields::Guardian::PHONE).to eq("guardian_phone")
      expect(UserComplianceInfoFields::Guardian::DATE_OF_BIRTH).to eq("guardian_birthday")
      expect(UserComplianceInfoFields::Guardian::TAX_ID).to eq("guardian_individual_tax_id")
    end

    it "defines guardian document verification fields" do
      expect(UserComplianceInfoFields::Guardian::STRIPE_IDENTITY_DOCUMENT_ID).to eq("guardian_stripe_identity_document_id")
      expect(UserComplianceInfoFields::Guardian::STRIPE_ADDITIONAL_DOCUMENT_ID).to eq("guardian_stripe_additional_document_id")
    end

    it "defines guardian date of birth component fields" do
      expect(UserComplianceInfoFields::Guardian::DOB_DAY).to eq("guardian_dob_day")
      expect(UserComplianceInfoFields::Guardian::DOB_MONTH).to eq("guardian_dob_month")
      expect(UserComplianceInfoFields::Guardian::DOB_YEAR).to eq("guardian_dob_year")
    end

    it "defines guardian terms of service field" do
      expect(UserComplianceInfoFields::Guardian::STRIPE_TOS_ACCEPTED).to eq("guardian_stripe_tos_accepted")
    end
  end

  describe "Guardian address constants" do
    it "defines all required guardian address fields" do
      expect(UserComplianceInfoFields::Guardian::Address::STREET).to eq("guardian_street_address")
      expect(UserComplianceInfoFields::Guardian::Address::CITY).to eq("guardian_city")
      expect(UserComplianceInfoFields::Guardian::Address::STATE).to eq("guardian_state")
      expect(UserComplianceInfoFields::Guardian::Address::ZIP_CODE).to eq("guardian_zip_code")
      expect(UserComplianceInfoFields::Guardian::Address::COUNTRY).to eq("guardian_country")
    end
  end

  describe "ALL_FIELDS constant" do
    it "includes all guardian field constants" do
      expected_fields = [
        "guardian_first_name",
        "guardian_last_name",
        "guardian_email",
        "guardian_phone",
        "guardian_birthday",
        "guardian_individual_tax_id",
        "guardian_stripe_identity_document_id",
        "guardian_stripe_additional_document_id",
        "guardian_dob_day",
        "guardian_dob_month",
        "guardian_dob_year",
        "guardian_stripe_tos_accepted",
        "guardian_street_address",
        "guardian_city",
        "guardian_state",
        "guardian_zip_code",
        "guardian_country"
      ]

      expect(UserComplianceInfoFields::Guardian::ALL_FIELDS).to contain_exactly(*expected_fields)
    end

    it "is frozen to prevent modification" do
      expect(UserComplianceInfoFields::Guardian::ALL_FIELDS).to be_frozen
    end
  end

  describe "ALL_FIELDS constant access" do
    it "is accessible via UserComplianceInfoFields::Guardian module" do
      expect(UserComplianceInfoFields::Guardian::ALL_FIELDS).to be_present
    end

    it "returns consistent results across multiple accesses" do
      first_access = UserComplianceInfoFields::Guardian::ALL_FIELDS
      second_access = UserComplianceInfoFields::Guardian::ALL_FIELDS

      expect(first_access).to eq(second_access)
      expect(first_access.object_id).to eq(second_access.object_id)
    end
  end

  describe "field naming consistency" do
    it "uses consistent guardian_ prefix for all fields" do
      UserComplianceInfoFields::Guardian::ALL_FIELDS.each do |field|
        expect(field).to start_with("guardian_"), "Field '#{field}' should start with 'guardian_'"
      end
    end

    it "uses snake_case naming convention" do
      UserComplianceInfoFields::Guardian::ALL_FIELDS.each do |field|
        expect(field).to match(/\A[a-z_]+\z/), "Field '#{field}' should use snake_case naming"
      end
    end

    it "does not have duplicate field names" do
      fields = UserComplianceInfoFields::Guardian::ALL_FIELDS
      unique_fields = fields.uniq

      expect(fields.length).to eq(unique_fields.length), "ALL_FIELDS should not contain duplicates"
    end
  end

  describe "integration with UserComplianceInfo model" do
    let(:user) { create(:user_with_compliance_info) }
    let(:user_compliance_info) { user.alive_user_compliance_info }

    it "all guardian fields correspond to actual model attributes or json_data accessors" do
      text_fields = [
        "guardian_first_name",
        "guardian_last_name",
        "guardian_email",
        "guardian_phone",
        "guardian_street_address",
        "guardian_city",
        "guardian_state",
        "guardian_zip_code",
        "guardian_country",
        "guardian_dob_day",
        "guardian_dob_month",
        "guardian_dob_year",
        "guardian_stripe_tos_accepted"
      ]

      text_fields.each do |field|
        expect(user_compliance_info).to respond_to(field), "UserComplianceInfo should respond to #{field}"
        expect(user_compliance_info).to respond_to("#{field}="), "UserComplianceInfo should have setter for #{field}"
      end
    end

    it "guardian_individual_tax_id corresponds to encrypted model attribute" do
      expect(user_compliance_info).to respond_to(:guardian_individual_tax_id)
      expect(user_compliance_info).to respond_to(:guardian_individual_tax_id=)
    end

    it "guardian_birthday corresponds to computed method" do
      expect(user_compliance_info).to respond_to(:guardian_birthday)
    end

    it "document fields are included for future Stripe integration" do
      document_fields = [
        "guardian_stripe_identity_document_id",
        "guardian_stripe_additional_document_id"
      ]

      document_fields.each do |field|
        expect(UserComplianceInfoFields::Guardian::ALL_FIELDS).to include(field)
      end
    end
  end

  describe "field categorization" do
    it "includes personal information fields" do
      personal_fields = [
        "guardian_first_name",
        "guardian_last_name",
        "guardian_email",
        "guardian_phone",
        "guardian_birthday",
        "guardian_dob_day",
        "guardian_dob_month",
        "guardian_dob_year"
      ]

      personal_fields.each do |field|
        expect(UserComplianceInfoFields::Guardian::ALL_FIELDS).to include(field)
      end
    end

    it "includes address fields" do
      address_fields = [
        "guardian_street_address",
        "guardian_city",
        "guardian_state",
        "guardian_zip_code",
        "guardian_country"
      ]

      address_fields.each do |field|
        expect(UserComplianceInfoFields::Guardian::ALL_FIELDS).to include(field)
      end
    end

    it "includes verification and compliance fields" do
      compliance_fields = [
        "guardian_individual_tax_id",
        "guardian_stripe_identity_document_id",
        "guardian_stripe_additional_document_id",
        "guardian_stripe_tos_accepted"
      ]

      compliance_fields.each do |field|
        expect(UserComplianceInfoFields::Guardian::ALL_FIELDS).to include(field)
      end
    end
  end

  describe "field count validation" do
    it "contains expected number of fields" do
      # This test ensures we don't accidentally add or remove fields
      # Update this number if intentionally changing the field count
      expected_count = 17

      expect(UserComplianceInfoFields::Guardian::ALL_FIELDS.length).to eq(expected_count)
    end
  end
end
