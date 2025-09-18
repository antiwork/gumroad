# frozen_string_literal: true

require "spec_helper"

RSpec.describe UserComplianceInfo, "guardian functionality", type: :model do
  let(:user) { create(:user) }
  let(:user_compliance_info) { create(:user_compliance_info, user: user) }

  describe "guardian methods" do
    describe "#guardian_first_and_last_name" do
      it "returns concatenated guardian name" do
        user_compliance_info.update!(guardian_first_name: "John", guardian_last_name: "Doe")
        expect(user_compliance_info.guardian_first_and_last_name).to eq("John Doe")
      end

      it "handles extra spaces" do
        user_compliance_info.update!(guardian_first_name: "  John  ", guardian_last_name: "  Doe  ")
        expect(user_compliance_info.guardian_first_and_last_name).to eq("John Doe")
      end
    end

    describe "#guardian_verification_required?" do
      context "when user is under 18" do
        before { user_compliance_info.update!(birthday: 16.years.ago) }

        it "returns true when guardian verification is required" do
          user_compliance_info.update!(country: "United States")
          expect(user_compliance_info.guardian_verification_required?).to be true
        end

        it "returns false when guardian verification is not required" do
          user_compliance_info.update!(country: "United States")
          allow(GuardianComplianceInfoRequest).to receive(:requires_guardian_verification?).and_return(false)
          expect(user_compliance_info.guardian_verification_required?).to be false
        end
      end

      context "when user is 18 or older" do
        before { user_compliance_info.update!(birthday: 20.years.ago) }

        it "returns false" do
          expect(user_compliance_info.guardian_verification_required?).to be false
        end
      end
    end

    describe "#guardian_verification_complete?" do
      context "when guardian verification is not required" do
        before { allow(user_compliance_info).to receive(:guardian_verification_required?).and_return(false) }

        it "returns true" do
          expect(user_compliance_info.guardian_verification_complete?).to be true
        end
      end

      context "when guardian verification is required" do
        before { allow(user_compliance_info).to receive(:guardian_verification_required?).and_return(true) }

        it "returns true when no pending requests" do
          expect(user_compliance_info.guardian_verification_complete?).to be true
        end

        it "returns false when there are pending requests" do
          create(:guardian_compliance_info_request, user: user, state: "requested")
          expect(user_compliance_info.guardian_verification_complete?).to be false
        end
      end
    end

    describe "#guardian_verification_status" do
      context "when guardian verification is not required" do
        before { allow(user_compliance_info).to receive(:guardian_verification_required?).and_return(false) }

        it "returns 'not_required'" do
          expect(user_compliance_info.guardian_verification_status).to eq("not_required")
        end
      end

      context "when guardian verification is required" do
        before { allow(user_compliance_info).to receive(:guardian_verification_required?).and_return(true) }

        it "returns 'complete' when verification is complete" do
          allow(user_compliance_info).to receive(:guardian_verification_complete?).and_return(true)
          expect(user_compliance_info.guardian_verification_status).to eq("complete")
        end

        it "returns 'pending' when there are pending requests" do
          allow(user_compliance_info).to receive(:guardian_verification_complete?).and_return(false)
          create(:guardian_compliance_info_request, user: user, state: "requested")
          expect(user_compliance_info.guardian_verification_status).to eq("pending")
        end

        it "returns 'incomplete' when no requests exist" do
          allow(user_compliance_info).to receive(:guardian_verification_complete?).and_return(false)
          expect(user_compliance_info.guardian_verification_status).to eq("incomplete")
        end
      end
    end
  end

  describe "callbacks" do
    describe "after_create_commit :handle_guardian_compliance_info_request" do
      it "calls GuardianComplianceInfoRequest.handle_new_guardian_compliance_info" do
        expect(GuardianComplianceInfoRequest).to receive(:handle_new_guardian_compliance_info)
        create(:user_compliance_info, user: user, birthday: 16.years.ago, country: "United States")
      end
    end
  end

  describe "encryption" do
    it "encrypts guardian_individual_tax_id" do
      user_compliance_info.update!(guardian_individual_tax_id: "123456789")
      expect(user_compliance_info.guardian_individual_tax_id).not_to eq("123456789")
    end
  end

  describe "stripped fields" do
    it "strips whitespace from guardian name fields" do
      user_compliance_info.update!(
        guardian_first_name: "  John  ",
        guardian_last_name: "  Doe  ",
        guardian_street_address: "  123 Main St  ",
        guardian_city: "  New York  ",
        guardian_zip_code: "  10001  "
      )

      expect(user_compliance_info.guardian_first_name).to eq("John")
      expect(user_compliance_info.guardian_last_name).to eq("Doe")
      expect(user_compliance_info.guardian_street_address).to eq("123 Main St")
      expect(user_compliance_info.guardian_city).to eq("New York")
      expect(user_compliance_info.guardian_zip_code).to eq("10001")
    end
  end
end
