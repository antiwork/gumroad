# frozen_string_literal: true

require "spec_helper"

RSpec.describe GuardianComplianceInfoRequest, type: :model do
  let(:user) { create(:user) }
  let(:user_compliance_info) { create(:user_compliance_info, user: user, birthday: 16.years.ago) }

  describe "associations" do
    it { should belong_to(:user) }
  end

  describe "validations" do
    it { should validate_presence_of(:user) }
    it { should validate_presence_of(:field_needed) }
  end

  describe "state machine" do
    it "starts in requested state" do
      request = create(:guardian_compliance_info_request, user: user)
      expect(request.state).to eq("requested")
    end

    it "transitions to provided state" do
      request = create(:guardian_compliance_info_request, user: user)
      request.mark_provided!
      expect(request.state).to eq("provided")
      expect(request.provided_at).to be_present
    end
  end

  describe "scopes" do
    let!(:requested_request) { create(:guardian_compliance_info_request, user: user, state: "requested") }
    let!(:provided_request) { create(:guardian_compliance_info_request, user: user, state: "provided") }

    describe ".requested" do
      it "returns only requested requests" do
        expect(GuardianComplianceInfoRequest.requested).to include(requested_request)
        expect(GuardianComplianceInfoRequest.requested).not_to include(provided_request)
      end
    end

    describe ".provided" do
      it "returns only provided requests" do
        expect(GuardianComplianceInfoRequest.provided).to include(provided_request)
        expect(GuardianComplianceInfoRequest.provided).not_to include(requested_request)
      end
    end
  end

  describe ".requires_guardian_verification?" do
    context "when user is under 18" do
      before { user_compliance_info.update!(birthday: 16.years.ago) }

      it "returns true for US users" do
        user_compliance_info.update!(country: "United States")
        expect(GuardianComplianceInfoRequest.requires_guardian_verification?(user_compliance_info)).to be true
      end

      it "returns true for Canadian users" do
        user_compliance_info.update!(country: "Canada")
        expect(GuardianComplianceInfoRequest.requires_guardian_verification?(user_compliance_info)).to be true
      end

      it "returns true for UK users" do
        user_compliance_info.update!(country: "United Kingdom")
        expect(GuardianComplianceInfoRequest.requires_guardian_verification?(user_compliance_info)).to be true
      end

      it "returns true for other countries by default" do
        user_compliance_info.update!(country: "Germany")
        expect(GuardianComplianceInfoRequest.requires_guardian_verification?(user_compliance_info)).to be true
      end
    end

    context "when user is 18 or older" do
      before { user_compliance_info.update!(birthday: 20.years.ago) }

      it "returns false" do
        user_compliance_info.update!(country: "United States")
        expect(GuardianComplianceInfoRequest.requires_guardian_verification?(user_compliance_info)).to be false
      end
    end
  end

  describe ".guardian_fields_for_country" do
    it "returns base fields for UK" do
      fields = GuardianComplianceInfoRequest.guardian_fields_for_country("GB")
      expect(fields).to include(GuardianComplianceInfoFields::FIRST_NAME)
      expect(fields).to include(GuardianComplianceInfoFields::LAST_NAME)
      expect(fields).to include(GuardianComplianceInfoFields::TAX_ID)
    end

    it "returns base fields plus tax ID for US" do
      fields = GuardianComplianceInfoRequest.guardian_fields_for_country("US")
      expect(fields).to include(GuardianComplianceInfoFields::FIRST_NAME)
      expect(fields).to include(GuardianComplianceInfoFields::TAX_ID)
    end

    it "returns base fields plus tax ID for Canada" do
      fields = GuardianComplianceInfoRequest.guardian_fields_for_country("CA")
      expect(fields).to include(GuardianComplianceInfoFields::FIRST_NAME)
      expect(fields).to include(GuardianComplianceInfoFields::TAX_ID)
    end
  end

  describe ".guardian_field_provided?" do
    let(:user_compliance_info) { create(:user_compliance_info, user: user) }

    it "returns true when guardian first name is provided" do
      user_compliance_info.update!(guardian_first_name: "John")
      expect(GuardianComplianceInfoRequest.guardian_field_provided?(user_compliance_info, GuardianComplianceInfoFields::FIRST_NAME)).to be true
    end

    it "returns false when guardian first name is not provided" do
      expect(GuardianComplianceInfoRequest.guardian_field_provided?(user_compliance_info, GuardianComplianceInfoFields::FIRST_NAME)).to be false
    end

    it "returns true when guardian tax ID is provided" do
      user_compliance_info.update!(guardian_individual_tax_id: "123456789")
      expect(GuardianComplianceInfoRequest.guardian_field_provided?(user_compliance_info, GuardianComplianceInfoFields::TAX_ID)).to be true
    end
  end

  describe ".create_guardian_verification_requests" do
    let(:user_compliance_info) { create(:user_compliance_info, user: user, birthday: 16.years.ago, country: "United States") }

    it "creates requests for missing guardian fields" do
      expect {
        GuardianComplianceInfoRequest.create_guardian_verification_requests(user_compliance_info)
      }.to change(GuardianComplianceInfoRequest, :count).by_at_least(5)

      expect(user.guardian_compliance_info_requests.pluck(:field_needed)).to include(
        GuardianComplianceInfoFields::FIRST_NAME,
        GuardianComplianceInfoFields::LAST_NAME,
        GuardianComplianceInfoFields::DATE_OF_BIRTH
      )
    end

    it "does not create duplicate requests" do
      GuardianComplianceInfoRequest.create_guardian_verification_requests(user_compliance_info)
      initial_count = GuardianComplianceInfoRequest.count

      GuardianComplianceInfoRequest.create_guardian_verification_requests(user_compliance_info)
      expect(GuardianComplianceInfoRequest.count).to eq(initial_count)
    end

    it "does not create requests for already provided fields" do
      user_compliance_info.update!(guardian_first_name: "John", guardian_last_name: "Doe")

      GuardianComplianceInfoRequest.create_guardian_verification_requests(user_compliance_info)

      expect(user.guardian_compliance_info_requests.pluck(:field_needed)).not_to include(
        GuardianComplianceInfoFields::FIRST_NAME,
        GuardianComplianceInfoFields::LAST_NAME
      )
    end
  end

  describe ".handle_new_guardian_compliance_info" do
    let(:user_compliance_info) { create(:user_compliance_info, user: user, birthday: 16.years.ago, country: "United States") }

    it "creates guardian verification requests for users under 18" do
      expect {
        GuardianComplianceInfoRequest.handle_new_guardian_compliance_info(user_compliance_info)
      }.to change(GuardianComplianceInfoRequest, :count).by_at_least(5)
    end

    it "does not create requests for users 18 or older" do
      user_compliance_info.update!(birthday: 20.years.ago)

      expect {
        GuardianComplianceInfoRequest.handle_new_guardian_compliance_info(user_compliance_info)
      }.not_to change(GuardianComplianceInfoRequest, :count)
    end
  end

  describe "email tracking" do
    let(:request) { create(:guardian_compliance_info_request, user: user) }

    it "tracks emails sent" do
      time = Time.current
      request.record_email_sent!(time)

      expect(request.emails_sent_at).to include(time)
      expect(request.last_email_sent_at).to eq(time)
    end

    it "defaults to current time when no time provided" do
      freeze_time do
        request.record_email_sent!
        expect(request.last_email_sent_at).to eq(Time.current)
      end
    end
  end
end
