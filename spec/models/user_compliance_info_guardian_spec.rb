# frozen_string_literal: true

require "spec_helper"

describe UserComplianceInfo, "guardian verification" do
  let(:user) { create(:user) }
  let(:user_compliance_info) { UserComplianceInfo.create!(user: user, birthday: 17.years.ago) }

  describe "#user_under_18?" do
    context "when user is under 18" do
      before { user_compliance_info.update!(birthday: 17.years.ago) }

      it "returns true" do
        expect(user_compliance_info.user_under_18?).to be true
      end
    end

    context "when user is exactly 18" do
      before { user_compliance_info.update!(birthday: 18.years.ago) }

      it "returns false" do
        expect(user_compliance_info.user_under_18?).to be false
      end
    end

    context "when user is over 18" do
      before { user_compliance_info.update!(birthday: 19.years.ago) }

      it "returns false" do
        expect(user_compliance_info.user_under_18?).to be false
      end
    end

    context "when birthday is not set" do
      before { user_compliance_info.update!(birthday: nil) }

      it "returns false" do
        expect(user_compliance_info.user_under_18?).to be false
      end
    end
  end

  describe "#guardian_verification_required?" do
    context "when user is under 18 and guardian fields are complete" do
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
          guardian_date_of_birth: 40.years.ago,
          guardian_stripe_tos_accepted: true,
          guardian_stripe_processing_tos_accepted: true
        )
      end

      it "returns true" do
        expect(user_compliance_info.guardian_verification_required?).to be true
      end
    end

    context "when user is under 18 but guardian fields are incomplete" do
      before do
        user_compliance_info.update!(
          birthday: 17.years.ago,
          guardian_first_name: "John",
          guardian_last_name: "Doe"
          # Missing other required fields
        )
      end

      it "returns false" do
        expect(user_compliance_info.guardian_verification_required?).to be false
      end
    end

    context "when user is 18 or older" do
      before { user_compliance_info.update!(birthday: 19.years.ago) }

      it "returns false" do
        expect(user_compliance_info.guardian_verification_required?).to be false
      end
    end
  end

  describe "#guardian_fields_complete_safe?" do
    context "when all required guardian fields are present" do
      before do
        user_compliance_info.update!(
          guardian_first_name: "John",
          guardian_last_name: "Doe",
          guardian_email: "guardian@example.com",
          guardian_phone: "555-1234",
          guardian_street_address: "123 Main St",
          guardian_city: "Anytown",
          guardian_state: "CA",
          guardian_zip_code: "12345",
          guardian_date_of_birth: 40.years.ago,
          guardian_stripe_tos_accepted: true,
          guardian_stripe_processing_tos_accepted: true
        )
      end

      it "returns true" do
        expect(user_compliance_info.guardian_fields_complete_safe?).to be true
      end
    end

    context "when some required guardian fields are missing" do
      before do
        user_compliance_info.update!(
          guardian_first_name: "John",
          guardian_last_name: "Doe"
          # Missing other required fields
        )
      end

      it "returns false" do
        expect(user_compliance_info.guardian_fields_complete_safe?).to be false
      end
    end
  end

  describe "guardian field validations" do
    context "when user is under 18" do
      before { user_compliance_info.update!(birthday: 17.years.ago) }

      it "requires guardian_first_name" do
        user_compliance_info.guardian_first_name = nil
        expect(user_compliance_info).not_to be_valid
        expect(user_compliance_info.errors[:guardian_first_name]).to include("can't be blank")
      end

      it "requires guardian_last_name" do
        user_compliance_info.guardian_last_name = nil
        expect(user_compliance_info).not_to be_valid
        expect(user_compliance_info.errors[:guardian_last_name]).to include("can't be blank")
      end

      it "requires guardian_email" do
        user_compliance_info.guardian_email = nil
        expect(user_compliance_info).not_to be_valid
        expect(user_compliance_info.errors[:guardian_email]).to include("can't be blank")
      end

      it "requires guardian_phone" do
        user_compliance_info.guardian_phone = nil
        expect(user_compliance_info).not_to be_valid
        expect(user_compliance_info.errors[:guardian_phone]).to include("can't be blank")
      end

      it "requires guardian_street_address" do
        user_compliance_info.guardian_street_address = nil
        expect(user_compliance_info).not_to be_valid
        expect(user_compliance_info.errors[:guardian_street_address]).to include("can't be blank")
      end

      it "requires guardian_city" do
        user_compliance_info.guardian_city = nil
        expect(user_compliance_info).not_to be_valid
        expect(user_compliance_info.errors[:guardian_city]).to include("can't be blank")
      end

      it "requires guardian_date_of_birth" do
        user_compliance_info.guardian_date_of_birth = nil
        expect(user_compliance_info).not_to be_valid
        expect(user_compliance_info.errors[:guardian_date_of_birth]).to include("can't be blank")
      end

      it "requires guardian_stripe_tos_accepted" do
        user_compliance_info.guardian_stripe_tos_accepted = false
        expect(user_compliance_info).not_to be_valid
        expect(user_compliance_info.errors[:guardian_stripe_tos_accepted]).to include("must be accepted")
      end

      it "requires guardian_stripe_processing_tos_accepted" do
        user_compliance_info.guardian_stripe_processing_tos_accepted = false
        expect(user_compliance_info).not_to be_valid
        expect(user_compliance_info.errors[:guardian_stripe_processing_tos_accepted]).to include("must be accepted")
      end
    end

    context "when user is 18 or older" do
      before { user_compliance_info.update!(birthday: 19.years.ago) }

      it "does not require guardian fields" do
        user_compliance_info.guardian_first_name = nil
        user_compliance_info.guardian_last_name = nil
        user_compliance_info.guardian_email = nil
        user_compliance_info.guardian_phone = nil
        user_compliance_info.guardian_street_address = nil
        user_compliance_info.guardian_city = nil
        user_compliance_info.guardian_date_of_birth = nil
        user_compliance_info.guardian_stripe_tos_accepted = false
        user_compliance_info.guardian_stripe_processing_tos_accepted = false

        expect(user_compliance_info).to be_valid
      end
    end
  end

  describe "guardian verification status" do
    context "when user is under 18" do
      before { user_compliance_info.update!(birthday: 17.years.ago) }

      context "with incomplete guardian fields" do
        it "returns 'incomplete'" do
          expect(user_compliance_info.guardian_verification_status).to eq("incomplete")
        end
      end

      context "with complete guardian fields" do
        before do
          user_compliance_info.update!(
            guardian_first_name: "John",
            guardian_last_name: "Doe",
            guardian_email: "guardian@example.com",
            guardian_phone: "555-1234",
            guardian_street_address: "123 Main St",
            guardian_city: "Anytown",
            guardian_state: "CA",
            guardian_zip_code: "12345",
            guardian_date_of_birth: 40.years.ago,
            guardian_stripe_tos_accepted: true,
            guardian_stripe_processing_tos_accepted: true
          )
        end

        it "returns 'pending'" do
          expect(user_compliance_info.guardian_verification_status).to eq("pending")
        end
      end
    end

    context "when user is 18 or older" do
      before { user_compliance_info.update!(birthday: 19.years.ago) }

      it "returns 'not_required'" do
        expect(user_compliance_info.guardian_verification_status).to eq("not_required")
      end
    end
  end

  describe "age-out cleanup" do
    context "when user turns 18 or older" do
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
          guardian_date_of_birth: 40.years.ago,
          guardian_stripe_tos_accepted: true,
          guardian_stripe_processing_tos_accepted: true,
          guardian_verification_status: "verified"
        )
      end

      it "clears all guardian information when birthday is updated" do
        expect {
          user_compliance_info.update!(birthday: 19.years.ago)
        }.to change { user_compliance_info.guardian_first_name }.to(nil)
         .and change { user_compliance_info.guardian_last_name }.to(nil)
         .and change { user_compliance_info.guardian_email }.to(nil)
         .and change { user_compliance_info.guardian_phone }.to(nil)
         .and change { user_compliance_info.guardian_street_address }.to(nil)
         .and change { user_compliance_info.guardian_city }.to(nil)
         .and change { user_compliance_info.guardian_state }.to(nil)
         .and change { user_compliance_info.guardian_zip_code }.to(nil)
         .and change { user_compliance_info.guardian_date_of_birth }.to(nil)
         .and change { user_compliance_info.guardian_individual_tax_id }.to(nil)
         .and change { user_compliance_info.guardian_stripe_tos_accepted }.to(false)
         .and change { user_compliance_info.guardian_stripe_processing_tos_accepted }.to(false)
         .and change { user_compliance_info.guardian_verification_status }.to("not_required")
      end
    end

    context "when user is already 18 or older" do
      before { user_compliance_info.update!(birthday: 19.years.ago) }

      it "does not clear guardian information when birthday is updated again" do
        user_compliance_info.update!(
          guardian_first_name: "John",
          guardian_last_name: "Doe"
        )

        expect {
          user_compliance_info.update!(birthday: 20.years.ago)
        }.not_to change { user_compliance_info.guardian_first_name }
      end
    end
  end

  describe "guardian verification status updates" do
    context "when guardian fields are updated" do
      before { user_compliance_info.update!(birthday: 17.years.ago) }

      it "updates verification status to pending when fields become complete" do
        expect {
          user_compliance_info.update!(
            guardian_first_name: "John",
            guardian_last_name: "Doe",
            guardian_email: "guardian@example.com",
            guardian_phone: "555-1234",
            guardian_street_address: "123 Main St",
            guardian_city: "Anytown",
            guardian_state: "CA",
            guardian_zip_code: "12345",
            guardian_date_of_birth: 40.years.ago,
            guardian_stripe_tos_accepted: true,
            guardian_stripe_processing_tos_accepted: true
          )
        }.to change { user_compliance_info.guardian_verification_status }.to("pending")
      end

      it "updates verification status to incomplete when fields become incomplete" do
        user_compliance_info.update!(
          guardian_first_name: "John",
          guardian_last_name: "Doe",
          guardian_email: "guardian@example.com",
          guardian_phone: "555-1234",
          guardian_street_address: "123 Main St",
          guardian_city: "Anytown",
          guardian_state: "CA",
          guardian_zip_code: "12345",
          guardian_date_of_birth: 40.years.ago,
          guardian_stripe_tos_accepted: true,
          guardian_stripe_processing_tos_accepted: true
        )

        expect {
          user_compliance_info.update!(guardian_first_name: nil)
        }.to change { user_compliance_info.guardian_verification_status }.to("incomplete")
      end
    end
  end
end
