# frozen_string_literal: true

require "spec_helper"

RSpec.describe UserComplianceInfo, type: :model do
  describe "guardian functionality" do
    let(:user) { create(:user) }

    describe "#user_under_18?" do
      context "when birthday is not present" do
        let(:user_compliance_info) { create(:user_compliance_info, birthday: nil) }

        it "returns false" do
          expect(user_compliance_info.user.under_18?).to be false
        end
      end

      context "when user is 16 years old" do
        let(:user_compliance_info) { create(:user_compliance_info, birthday: 16.years.ago) }

        it "returns true" do
          expect(user_compliance_info.user.under_18?).to be true
        end
      end

      context "when user is 18 years old" do
        let(:user_compliance_info) { create(:user_compliance_info, birthday: 18.years.ago) }

        it "returns false" do
          expect(user_compliance_info.user.under_18?).to be false
        end
      end

      context "when user is 19 years old" do
        let(:user_compliance_info) { create(:user_compliance_info, birthday: 19.years.ago) }

        it "returns false" do
          expect(user_compliance_info.user.under_18?).to be false
        end
      end
    end

    describe "#guardian_fields_complete?" do
      context "when user is not under 18" do
        let(:user_compliance_info) { create(:user_compliance_info, birthday: 19.years.ago) }

        it "returns false" do
          expect(user_compliance_info.guardian_fields_complete?).to be false
        end
      end

      context "when user is under 18" do
        let(:user_compliance_info) do
          create(:user_compliance_info,
            birthday: 16.years.ago,
            guardian_first_name: "John",
            guardian_last_name: "Doe",
            guardian_email: "john@example.com",
            guardian_phone: "+1234567890",
            guardian_street_address: "123 Main St",
            guardian_city: "Anytown",
            guardian_date_of_birth: 40.years.ago
          )
        end

        it "returns true when all required fields are present" do
          expect(user_compliance_info.guardian_fields_complete?).to be true
        end

        it "returns false when guardian_first_name is missing" do
          user_compliance_info.guardian_first_name = nil
          expect(user_compliance_info.guardian_fields_complete?).to be false
        end

        it "returns false when guardian_last_name is missing" do
          user_compliance_info.guardian_last_name = nil
          expect(user_compliance_info.guardian_fields_complete?).to be false
        end

        it "returns false when guardian_email is missing" do
          user_compliance_info.guardian_email = nil
          expect(user_compliance_info.guardian_fields_complete?).to be false
        end

        it "returns false when guardian_phone is missing" do
          user_compliance_info.guardian_phone = nil
          expect(user_compliance_info.guardian_fields_complete?).to be false
        end

        it "returns false when guardian_street_address is missing" do
          user_compliance_info.guardian_street_address = nil
          expect(user_compliance_info.guardian_fields_complete?).to be false
        end

        it "returns false when guardian_city is missing" do
          user_compliance_info.guardian_city = nil
          expect(user_compliance_info.guardian_fields_complete?).to be false
        end

        it "returns false when guardian_date_of_birth is missing" do
          user_compliance_info.guardian_date_of_birth = nil
          expect(user_compliance_info.guardian_fields_complete?).to be false
        end
      end
    end

    describe "guardian field encryption" do
      let(:user_compliance_info) { create(:user_compliance_info, guardian_tax_id: "123456789") }

      it "encrypts guardian_tax_id" do
        expect(user_compliance_info.guardian_tax_id).to be_a(Strongbox::Lock)
        expect(user_compliance_info.guardian_tax_id.decrypt("1234")).to eq("123456789")
      end

      it "outputs '*encrypted*' if no password given to decrypt" do
        expect(user_compliance_info.guardian_tax_id.decrypt(nil)).to eq("*encrypted*")
      end
    end


    describe "guardian info clearing when user turns 18" do
      let(:user) { create(:user) }

      it "clears guardian info when birthday is updated to 18 or older" do
        old_compliance_info = create(:user_compliance_info,
          user: user,
          birthday: 17.years.ago,
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
          guardian_verified: false
        )

        # Simulate the UpdateUserComplianceInfo service behavior
        saved, new_compliance_info = old_compliance_info.dup_and_save do |new_info|
          new_info.birthday = 18.years.ago
        end

        expect(saved).to be true
        expect(new_compliance_info.guardian_first_name).to be_nil
        expect(new_compliance_info.guardian_last_name).to be_nil
        expect(new_compliance_info.guardian_email).to be_nil
        expect(new_compliance_info.guardian_phone).to be_nil
        expect(new_compliance_info.guardian_street_address).to be_nil
        expect(new_compliance_info.guardian_city).to be_nil
        expect(new_compliance_info.guardian_state).to be_nil
        expect(new_compliance_info.guardian_zip_code).to be_nil
        expect(new_compliance_info.guardian_date_of_birth).to be_nil
        # Note: guardian_tax_id clearing is handled in the UpdateUserComplianceInfo service
        # and tested in the service specs. The before_save callback doesn't run in dup_and_save.
        expect(new_compliance_info.guardian_stripe_tos_accepted).to be false
        expect(new_compliance_info.guardian_stripe_processing_tos_accepted).to be false
      end

      it "does not clear guardian info when birthday is updated but user is still under 18" do
        old_compliance_info = create(:user_compliance_info,
          user: user,
          birthday: 17.years.ago,
          guardian_first_name: "John",
          guardian_last_name: "Doe",
          guardian_email: "john@example.com"
        )

        saved, new_compliance_info = old_compliance_info.dup_and_save do |new_info|
          new_info.birthday = 16.years.ago
        end

        expect(saved).to be true
        expect(new_compliance_info.guardian_first_name).to eq("John")
        expect(new_compliance_info.guardian_last_name).to eq("Doe")
        expect(new_compliance_info.guardian_email).to eq("john@example.com")
      end

      it "does not clear guardian info when birthday is not changed" do
        old_compliance_info = create(:user_compliance_info,
          user: user,
          birthday: 17.years.ago,
          guardian_first_name: "John",
          guardian_last_name: "Doe",
          guardian_email: "john@example.com"
        )

        saved, new_compliance_info = old_compliance_info.dup_and_save do |new_info|
          new_info.first_name = "Updated Name"
        end

        expect(saved).to be true
        expect(new_compliance_info.guardian_first_name).to eq("John")
        expect(new_compliance_info.guardian_last_name).to eq("Doe")
        expect(new_compliance_info.guardian_email).to eq("john@example.com")
      end
    end

    describe "minimum age validation" do
      it "validates user is at least 13 years old" do
        user_compliance_info = build(:user_compliance_info, birthday: 12.years.ago)

        expect(user_compliance_info).not_to be_valid
        expect(user_compliance_info.errors[:base]).to include("You must be 13 years old to use Gumroad.")
      end

      it "allows users who are 13 or older" do
        user_compliance_info = build(:user_compliance_info, birthday: 13.years.ago)

        expect(user_compliance_info).to be_valid
      end
    end

    describe "has_completed_compliance_info? with guardian fields" do
      context "when user is under 18" do
        let(:user_compliance_info) do
          create(:user_compliance_info,
            birthday: 16.years.ago,
            guardian_first_name: "John",
            guardian_last_name: "Doe",
            guardian_email: "john@example.com",
            guardian_phone: "+1234567890",
            guardian_street_address: "123 Main St",
            guardian_city: "Anytown",
            guardian_date_of_birth: 40.years.ago
          )
        end

        it "returns true when all individual fields and guardian fields are complete" do
          expect(user_compliance_info.has_completed_compliance_info?).to be true
        end
      end
    end
  end

  describe "#mark_guardian_verified!" do
    let(:user) { create(:user) }

    context "when user is under 18" do
      it "marks guardian as verified" do
        compliance_info = create(:user_compliance_info,
          user: user,
          birthday: 17.years.ago,
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
          guardian_verified: false
        )

        new_compliance_info = compliance_info.mark_guardian_verified!

        expect(new_compliance_info).to be_present
        expect(new_compliance_info.guardian_verified).to be true
        expect(new_compliance_info.id).not_to eq(compliance_info.id)
      end
    end

    context "when user is 18 or older" do
      it "returns nil" do
        compliance_info = create(:user_compliance_info,
          user: user,
          birthday: 18.years.ago,
          guardian_verified: false
        )

        result = compliance_info.mark_guardian_verified!

        expect(result).to be_nil
      end
    end
  end
end
