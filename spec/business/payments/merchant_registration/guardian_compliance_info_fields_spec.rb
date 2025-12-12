# frozen_string_literal: true

require "spec_helper"

RSpec.describe Guardian::RequestFields, type: :module do
  describe "Guardian field constants" do
    it "defines all required guardian personal fields" do
      expect(Guardian::RequestFields::FIRST_NAME).to eq("guardian_first_name")
      expect(Guardian::RequestFields::LAST_NAME).to eq("guardian_last_name")
      expect(Guardian::RequestFields::EMAIL).to eq("guardian_email")
      expect(Guardian::RequestFields::PHONE).to eq("guardian_phone")
      expect(Guardian::RequestFields::DATE_OF_BIRTH).to eq("guardian_birthday")
      expect(Guardian::RequestFields::TAX_ID).to eq("guardian_individual_tax_id")
    end

    it "defines guardian document verification fields" do
      expect(Guardian::RequestFields::STRIPE_IDENTITY_DOCUMENT_ID).to eq("guardian_stripe_identity_document_id")
      expect(Guardian::RequestFields::STRIPE_ADDITIONAL_DOCUMENT_ID).to eq("guardian_stripe_additional_document_id")
    end

    it "defines guardian date of birth component fields" do
      expect(Guardian::RequestFields::DOB_DAY).to eq("guardian_dob_day")
      expect(Guardian::RequestFields::DOB_MONTH).to eq("guardian_dob_month")
      expect(Guardian::RequestFields::DOB_YEAR).to eq("guardian_dob_year")
    end

    it "defines guardian terms of service field" do
      expect(Guardian::RequestFields::STRIPE_TOS_ACCEPTED).to eq("guardian_stripe_tos_accepted")
    end
  end

  describe "Guardian address constants" do
    it "defines all required guardian address fields" do
      expect(Guardian::RequestFields::Address::STREET).to eq("guardian_street_address")
      expect(Guardian::RequestFields::Address::CITY).to eq("guardian_city")
      expect(Guardian::RequestFields::Address::STATE).to eq("guardian_state")
      expect(Guardian::RequestFields::Address::ZIP_CODE).to eq("guardian_zip_code")
      expect(Guardian::RequestFields::Address::COUNTRY).to eq("guardian_country")
    end
  end

  describe "ALL constant" do
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

      expect(Guardian::RequestFields::ALL).to contain_exactly(*expected_fields)
    end

    it "is frozen to prevent modification" do
      expect(Guardian::RequestFields::ALL).to be_frozen
    end
  end

  describe "ALL constant access" do
    it "is accessible via Guardian::RequestFields module" do
      expect(Guardian::RequestFields::ALL).to be_present
    end

    it "returns consistent results across multiple accesses" do
      first_access = Guardian::RequestFields::ALL
      second_access = Guardian::RequestFields::ALL

      expect(first_access).to eq(second_access)
      expect(first_access.object_id).to eq(second_access.object_id)
    end
  end

  describe "field naming consistency" do
    it "uses consistent guardian_ prefix for all fields" do
      Guardian::RequestFields::ALL.each do |field|
        expect(field).to start_with("guardian_"), "Field '#{field}' should start with 'guardian_'"
      end
    end

    it "uses snake_case naming convention" do
      Guardian::RequestFields::ALL.each do |field|
        expect(field).to match(/\A[a-z_]+\z/), "Field '#{field}' should use snake_case naming"
      end
    end

    it "does not have duplicate field names" do
      fields = Guardian::RequestFields::ALL
      unique_fields = fields.uniq

      expect(fields.length).to eq(unique_fields.length), "ALL should not contain duplicates"
    end
  end

  describe "integration with Guardian model" do
    let(:guardian) { create(:guardian) }

    it "all guardian fields map to Guardian model attributes" do
      guardian_attributes = [
        :first_name,
        :last_name,
        :email,
        :phone,
        :street_address,
        :city,
        :state,
        :zip_code,
        :country,
        :date_of_birth,
        :stripe_tos_accepted
      ]

      guardian_attributes.each do |attribute|
        expect(guardian).to respond_to(attribute), "Guardian should respond to #{attribute}"
        expect(guardian).to respond_to("#{attribute}="), "Guardian should have setter for #{attribute}"
      end
    end

    it "guardian individual_tax_id corresponds to encrypted model attribute" do
      expect(guardian).to respond_to(:individual_tax_id)
      expect(guardian).to respond_to(:individual_tax_id=)
    end

    it "guardian date_of_birth is aliased as birthday" do
      expect(guardian).to respond_to(:birthday)
      guardian.date_of_birth = Date.new(1980, 1, 15)
      expect(guardian.birthday).to eq(Date.new(1980, 1, 15))
    end

    it "document fields are included for future Stripe integration" do
      document_fields = [
        "guardian_stripe_identity_document_id",
        "guardian_stripe_additional_document_id"
      ]

      document_fields.each do |field|
        expect(Guardian::RequestFields::ALL).to include(field)
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
        expect(Guardian::RequestFields::ALL).to include(field)
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
        expect(Guardian::RequestFields::ALL).to include(field)
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
        expect(Guardian::RequestFields::ALL).to include(field)
      end
    end
  end

  describe "field count validation" do
    it "contains expected number of fields" do
      expected_count = 17

      expect(Guardian::RequestFields::ALL.length).to eq(expected_count)
    end
  end

  describe "REQUEST_FIELD_TO_ATTRIBUTE mapping" do
    it "maps all request fields to Guardian model attributes" do
      expect(Guardian::REQUEST_FIELD_TO_ATTRIBUTE).to be_a(Hash)
      expect(Guardian::REQUEST_FIELD_TO_ATTRIBUTE).to be_frozen
    end

    it "maps field identifiers to correct attributes" do
      expect(Guardian::REQUEST_FIELD_TO_ATTRIBUTE[Guardian::RequestFields::FIRST_NAME]).to eq(:first_name)
      expect(Guardian::REQUEST_FIELD_TO_ATTRIBUTE[Guardian::RequestFields::LAST_NAME]).to eq(:last_name)
      expect(Guardian::REQUEST_FIELD_TO_ATTRIBUTE[Guardian::RequestFields::EMAIL]).to eq(:email)
      expect(Guardian::REQUEST_FIELD_TO_ATTRIBUTE[Guardian::RequestFields::PHONE]).to eq(:phone)
      expect(Guardian::REQUEST_FIELD_TO_ATTRIBUTE[Guardian::RequestFields::DATE_OF_BIRTH]).to eq(:date_of_birth)
      expect(Guardian::REQUEST_FIELD_TO_ATTRIBUTE[Guardian::RequestFields::TAX_ID]).to eq(:individual_tax_id)
      expect(Guardian::REQUEST_FIELD_TO_ATTRIBUTE[Guardian::RequestFields::Address::STREET]).to eq(:street_address)
      expect(Guardian::REQUEST_FIELD_TO_ATTRIBUTE[Guardian::RequestFields::Address::CITY]).to eq(:city)
      expect(Guardian::REQUEST_FIELD_TO_ATTRIBUTE[Guardian::RequestFields::Address::STATE]).to eq(:state)
      expect(Guardian::REQUEST_FIELD_TO_ATTRIBUTE[Guardian::RequestFields::Address::ZIP_CODE]).to eq(:zip_code)
      expect(Guardian::REQUEST_FIELD_TO_ATTRIBUTE[Guardian::RequestFields::Address::COUNTRY]).to eq(:country)
    end
  end

  describe "UserComplianceInfoFields integration" do
    it "exposes guardian fields via helper methods" do
      expect(UserComplianceInfoFields.all_guardian_fields).to eq(Guardian::RequestFields::ALL)
      expect(UserComplianceInfoFields.guardian_field_to_attribute).to eq(Guardian::REQUEST_FIELD_TO_ATTRIBUTE)
    end
  end
end
