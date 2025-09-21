# frozen_string_literal: true

require "spec_helper"

RSpec.describe UserComplianceInfo, type: :model do
  describe "guardian functionality" do
    let(:user) { create(:user) }
    let(:user_compliance_info) do
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
        guardian_individual_tax_id: "123456789",
        guardian_stripe_tos_accepted: true,
        guardian_stripe_processing_tos_accepted: true,
        country: "United States"
      )
    end

    describe "validations" do
      context "when user is under 18" do
        it "requires guardian first name" do
          user_compliance_info.guardian_first_name = nil
          expect(user_compliance_info).not_to be_valid
          expect(user_compliance_info.errors[:guardian_first_name]).to include("can't be blank")
        end

        it "requires guardian last name" do
          user_compliance_info.guardian_last_name = nil
          expect(user_compliance_info).not_to be_valid
          expect(user_compliance_info.errors[:guardian_last_name]).to include("can't be blank")
        end

        it "requires guardian email" do
          user_compliance_info.guardian_email = nil
          expect(user_compliance_info).not_to be_valid
          expect(user_compliance_info.errors[:guardian_email]).to include("can't be blank")
        end

        it "validates guardian email format" do
          user_compliance_info.guardian_email = "invalid-email"
          expect(user_compliance_info).not_to be_valid
          expect(user_compliance_info.errors[:guardian_email]).to include("is invalid")
        end

        it "requires guardian phone" do
          user_compliance_info.guardian_phone = nil
          expect(user_compliance_info).not_to be_valid
          expect(user_compliance_info.errors[:guardian_phone]).to include("can't be blank")
        end

        it "requires guardian street address" do
          user_compliance_info.guardian_street_address = nil
          expect(user_compliance_info).not_to be_valid
          expect(user_compliance_info.errors[:guardian_street_address]).to include("can't be blank")
        end

        it "requires guardian city" do
          user_compliance_info.guardian_city = nil
          expect(user_compliance_info).not_to be_valid
          expect(user_compliance_info.errors[:guardian_city]).to include("can't be blank")
        end

        it "requires guardian date of birth" do
          user_compliance_info.guardian_date_of_birth = nil
          expect(user_compliance_info).not_to be_valid
          expect(user_compliance_info.errors[:guardian_date_of_birth]).to include("can't be blank")
        end

        it "requires guardian stripe tos acceptance" do
          user_compliance_info.guardian_stripe_tos_accepted = false
          expect(user_compliance_info).not_to be_valid
          expect(user_compliance_info.errors[:guardian_stripe_tos_accepted]).to include("must be accepted")
        end

        it "requires guardian stripe processing tos acceptance" do
          user_compliance_info.guardian_stripe_processing_tos_accepted = false
          expect(user_compliance_info).not_to be_valid
          expect(user_compliance_info.errors[:guardian_stripe_processing_tos_accepted]).to include("must be accepted")
        end
      end

      context "when user is 18 or older" do
        let(:adult_user) { create(:user) }
        let(:adult_compliance_info) { create(:user_compliance_info, user: adult_user, birthday: 20.years.ago, country: "United States") }

        it "does not require guardian fields" do
          adult_compliance_info.guardian_first_name = nil
          adult_compliance_info.guardian_last_name = nil
          adult_compliance_info.guardian_email = nil
          adult_compliance_info.guardian_phone = nil
          adult_compliance_info.guardian_street_address = nil
          adult_compliance_info.guardian_city = nil
          adult_compliance_info.guardian_date_of_birth = nil
          adult_compliance_info.guardian_stripe_tos_accepted = false
          adult_compliance_info.guardian_stripe_processing_tos_accepted = false

          expect(adult_compliance_info).to be_valid
        end
      end

      context "guardian state validation" do
        it "requires guardian state for US" do
          user_compliance_info.country = "United States"
          user_compliance_info.guardian_state = nil
          expect(user_compliance_info).not_to be_valid
          expect(user_compliance_info.errors[:guardian_state]).to include("can't be blank")
        end

        it "requires guardian state for CA" do
          user_compliance_info.country = "Canada"
          user_compliance_info.guardian_state = nil
          expect(user_compliance_info).not_to be_valid
          expect(user_compliance_info.errors[:guardian_state]).to include("can't be blank")
        end

        it "does not require guardian state for countries that don't need it" do
          user_compliance_info.country = "United Kingdom"
          user_compliance_info.guardian_state = nil
          expect(user_compliance_info).to be_valid
        end
      end

      context "guardian zip code validation" do
        it "requires guardian zip code for most countries" do
          user_compliance_info.country = "United States"
          user_compliance_info.guardian_zip_code = nil
          expect(user_compliance_info).not_to be_valid
          expect(user_compliance_info.errors[:guardian_zip_code]).to include("can't be blank")
        end

        it "does not require guardian zip code for BW" do
          user_compliance_info.country = "Botswana"
          user_compliance_info.guardian_zip_code = nil
          expect(user_compliance_info).to be_valid
        end
      end

      context "guardian tax ID validation" do
        it "requires guardian tax ID for countries that need it" do
          # Create a new record without the tax ID to test validation
          new_record = build(:user_compliance_info,
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
            guardian_individual_tax_id: nil, # This should trigger validation
            guardian_stripe_tos_accepted: true,
            guardian_stripe_processing_tos_accepted: true,
            country: "United States"
          )
          expect(new_record).not_to be_valid
          expect(new_record.errors[:guardian_individual_tax_id]).to include("can't be blank")
        end

        it "does not require guardian tax ID for countries that don't need it" do
          # Create a new record without the tax ID for a country that doesn't need it
          new_record = build(:user_compliance_info,
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
            guardian_individual_tax_id: nil,
            guardian_stripe_tos_accepted: true,
            guardian_stripe_processing_tos_accepted: true,
            country: "United Kingdom"
          )
          expect(new_record).to be_valid
        end
      end

      context "guardian date of birth validation" do
        it "validates guardian date of birth is a valid date" do
          # Create a new record with an invalid date to test validation
          new_record = build(:user_compliance_info,
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
            guardian_date_of_birth: 123, # This should trigger custom validation (not a Date)
            guardian_individual_tax_id: "123456789",
            guardian_stripe_tos_accepted: true,
            guardian_stripe_processing_tos_accepted: true,
            country: "United States"
          )
          expect(new_record).not_to be_valid
          expect(new_record.errors[:guardian_date_of_birth]).to include("must be a valid date")
        end

        it "validates guardian date of birth is not in the future" do
          user_compliance_info.guardian_date_of_birth = 1.day.from_now
          expect(user_compliance_info).not_to be_valid
          expect(user_compliance_info.errors[:guardian_date_of_birth]).to include("cannot be in the future")
        end

        it "validates guardian is 18 or older" do
          user_compliance_info.guardian_date_of_birth = 17.years.ago
          expect(user_compliance_info).not_to be_valid
          expect(user_compliance_info.errors[:guardian_date_of_birth]).to include("guardian must be 18 years or older")
        end

        it "allows guardian who is exactly 18" do
          user_compliance_info.guardian_date_of_birth = 18.years.ago
          expect(user_compliance_info).to be_valid
        end
      end
    end

    describe "guardian_fields_complete?" do
      context "when user is under 18" do
        it "returns true when all required fields are present" do
          user_compliance_info.update!(
            guardian_first_name: "John",
            guardian_last_name: "Doe",
            guardian_email: "john@example.com",
            guardian_phone: "+1234567890",
            guardian_street_address: "123 Main St",
            guardian_city: "Anytown",
            guardian_date_of_birth: 30.years.ago,
            guardian_stripe_tos_accepted: true,
            guardian_stripe_processing_tos_accepted: true
          )

          expect(user_compliance_info.guardian_fields_complete?).to be true
        end

        it "returns false when required fields are missing" do
          user_compliance_info.guardian_first_name = nil
          expect(user_compliance_info.guardian_fields_complete?).to be false
        end

        it "returns false when guardian date of birth is missing" do
          user_compliance_info.guardian_date_of_birth = nil
          expect(user_compliance_info.guardian_fields_complete?).to be false
        end

        it "returns false when state is required but missing" do
          user_compliance_info.country = "United States"
          user_compliance_info.guardian_state = nil
          expect(user_compliance_info.guardian_fields_complete?).to be false
        end

        it "returns false when zip code is required but missing" do
          user_compliance_info.country = "United States"
          user_compliance_info.guardian_zip_code = nil
          expect(user_compliance_info.guardian_fields_complete?).to be false
        end

        it "returns false when tax ID is required but missing" do
          # Create a new record without the tax ID to test guardian_fields_complete?
          new_record = build(:user_compliance_info,
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
            guardian_individual_tax_id: nil, # Missing tax ID
            guardian_stripe_tos_accepted: true,
            guardian_stripe_processing_tos_accepted: true,
            country: "United States"
          )
          expect(new_record.guardian_fields_complete?).to be false
        end
      end

      context "when user is 18 or older" do
        let(:adult_user) { create(:user) }
        let(:adult_compliance_info) { create(:user_compliance_info, user: adult_user, birthday: 20.years.ago, country: "United States") }

        it "returns false" do
          expect(adult_compliance_info.guardian_fields_complete?).to be false
        end
      end
    end

    describe "guardian_state_required?" do
      it "returns true for countries that require states" do
        user_compliance_info.country = "United States"
        expect(user_compliance_info.guardian_state_required?).to be true

        user_compliance_info.country = "Canada"
        expect(user_compliance_info.guardian_state_required?).to be true

        user_compliance_info.country = "Australia"
        expect(user_compliance_info.guardian_state_required?).to be true
      end

      it "returns false for countries that don't require states" do
        user_compliance_info.country = "United Kingdom"
        expect(user_compliance_info.guardian_state_required?).to be false
      end

      it "returns false when user is 18 or older" do
        adult_user = create(:user)
        adult_compliance_info = create(:user_compliance_info, user: adult_user, country: "United States")
        expect(adult_compliance_info.guardian_state_required?).to be false
      end

      it "returns false when country code is not present" do
        user_compliance_info.country = nil
        expect(user_compliance_info.guardian_state_required?).to be false
      end
    end

    describe "guardian_zip_code_required?" do
      it "returns true for most countries" do
        user_compliance_info.country = "United States"
        expect(user_compliance_info.guardian_zip_code_required?).to be true

        user_compliance_info.country = "Canada"
        expect(user_compliance_info.guardian_zip_code_required?).to be true
      end

      it "returns false for BW" do
        user_compliance_info.country = "Botswana"
        expect(user_compliance_info.guardian_zip_code_required?).to be false
      end

      it "returns false when user is 18 or older" do
        adult_user = create(:user)
        adult_compliance_info = create(:user_compliance_info, user: adult_user, country: "United States")
        expect(adult_compliance_info.guardian_zip_code_required?).to be false
      end

      it "returns false when country code is not present" do
        user_compliance_info.country = nil
        expect(user_compliance_info.guardian_zip_code_required?).to be false
      end
    end

    describe "guardian_tax_id_required?" do
      it "returns true for countries that require tax IDs" do
        user_compliance_info.country = "United States"
        expect(user_compliance_info.guardian_tax_id_required?).to be true

        user_compliance_info.country = "Canada"
        expect(user_compliance_info.guardian_tax_id_required?).to be true
      end

      it "returns false for countries that don't require tax IDs" do
        user_compliance_info.country = "United Kingdom"
        expect(user_compliance_info.guardian_tax_id_required?).to be false
      end

      it "returns false when user is 18 or older" do
        adult_user = create(:user)
        adult_compliance_info = create(:user_compliance_info, user: adult_user, country: "United States")
        expect(adult_compliance_info.guardian_tax_id_required?).to be false
      end

      it "returns false when country code is not present" do
        user_compliance_info.country = nil
        expect(user_compliance_info.guardian_tax_id_required?).to be false
      end
    end

    describe "clear_guardian_info_if_user_is_18_or_older" do
      it "clears guardian info when user turns 18" do
        user_compliance_info.update!(
          guardian_first_name: "John",
          guardian_last_name: "Doe",
          guardian_email: "john@example.com",
          guardian_phone: "+1234567890",
          guardian_street_address: "123 Main St",
          guardian_city: "Anytown",
          guardian_state: "CA",
          guardian_zip_code: "12345",
          guardian_date_of_birth: 30.years.ago,
          guardian_individual_tax_id: "1234",
          guardian_stripe_tos_accepted: true,
          guardian_stripe_processing_tos_accepted: true,
        )

        # Simulate user turning 18
        user_compliance_info.update!(birthday: 18.years.ago)
        user_compliance_info.save!

        expect(user_compliance_info.guardian_first_name).to be_nil
        expect(user_compliance_info.guardian_last_name).to be_nil
        expect(user_compliance_info.guardian_email).to be_nil
        expect(user_compliance_info.guardian_phone).to be_nil
        expect(user_compliance_info.guardian_street_address).to be_nil
        expect(user_compliance_info.guardian_city).to be_nil
        expect(user_compliance_info.guardian_state).to be_nil
        expect(user_compliance_info.guardian_zip_code).to be_nil
        expect(user_compliance_info.guardian_date_of_birth).to be_nil
        # Check if the encrypted field is empty by looking at the decrypted value
        expect(user_compliance_info.guardian_individual_tax_id.decrypt(nil)).to eq("*encrypted*")
        expect(user_compliance_info.guardian_stripe_tos_accepted).to be false
        expect(user_compliance_info.guardian_stripe_processing_tos_accepted).to be false
      end

      it "does not clear guardian info when user is still under 18" do
        user_compliance_info.update!(
          guardian_first_name: "John",
          guardian_last_name: "Doe"
        )

        user_compliance_info.update!(birthday: 17.years.ago)
        user_compliance_info.save!

        expect(user_compliance_info.guardian_first_name).to eq("John")
        expect(user_compliance_info.guardian_last_name).to eq("Doe")
      end
    end

  end
end

