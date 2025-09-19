# frozen_string_literal: true

require "spec_helper"

describe StripeMerchantAccountManager, "guardian verification" do
  let(:user) { create(:user) }
  let(:user_compliance_info) { create(:user_compliance_info, user: user) }

  describe ".handle_guardian_person_verification_update" do
    let(:stripe_person) { {} }
    let(:stripe_previous_attributes) { {} }

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

    context "when verification status changes to verified" do
      let(:stripe_person) do
        {
          "verification" => { "status" => "verified" }
        }
      end
      let(:stripe_previous_attributes) do
        {
          "verification" => { "status" => "pending" }
        }
      end

      it "updates guardian verification status to verified" do
        expect {
          described_class.handle_guardian_person_verification_update(
            user, stripe_person, stripe_previous_attributes
          )
        }.to change { user_compliance_info.reload.guardian_verification_status }
          .to("verified")
      end

      it "marks guardian compliance requests as provided" do
        # Create some compliance requests
        guardian_fields = %w[
          guardian_first_name guardian_last_name guardian_email guardian_phone
          guardian_street_address guardian_city guardian_date_of_birth
        ]

        guardian_fields.each do |field|
          user.user_compliance_info_requests.create!(
            field_needed: field,
            state: 'requested'
          )
        end

        expect {
          described_class.handle_guardian_person_verification_update(
            user, stripe_person, stripe_previous_attributes
          )
        }.to change { user.user_compliance_info_requests.requested.count }
          .from(guardian_fields.length).to(0)
      end

      it "logs the verification completion" do
        expect(Rails.logger).to receive(:info).with("Guardian verification completed for user #{user.id}")

        described_class.handle_guardian_person_verification_update(
          user, stripe_person, stripe_previous_attributes
        )
      end
    end

    context "when verification status changes to pending" do
      let(:stripe_person) do
        {
          "verification" => { "status" => "pending" }
        }
      end
      let(:stripe_previous_attributes) do
        {
          "verification" => { "status" => "incomplete" }
        }
      end

      it "updates guardian verification status to pending" do
        expect {
          described_class.handle_guardian_person_verification_update(
            user, stripe_person, stripe_previous_attributes
          )
        }.to change { user_compliance_info.reload.guardian_verification_status }
          .to("pending")
      end
    end

    context "when verification status changes to unverified" do
      let(:stripe_person) do
        {
          "verification" => { "status" => "unverified" }
        }
      end
      let(:stripe_previous_attributes) do
        {
          "verification" => { "status" => "pending" }
        }
      end

      it "updates guardian verification status to incomplete" do
        expect {
          described_class.handle_guardian_person_verification_update(
            user, stripe_person, stripe_previous_attributes
          )
        }.to change { user_compliance_info.reload.guardian_verification_status }
          .to("incomplete")
      end
    end

    context "when verification status doesn't change" do
      let(:stripe_person) do
        {
          "verification" => { "status" => "pending" }
        }
      end
      let(:stripe_previous_attributes) do
        {
          "verification" => { "status" => "pending" }
        }
      end

      it "does not update guardian verification status" do
        expect {
          described_class.handle_guardian_person_verification_update(
            user, stripe_person, stripe_previous_attributes
          )
        }.not_to change { user_compliance_info.reload.guardian_verification_status }
      end
    end

    context "when user is 18 or older" do
      before { user_compliance_info.update!(birthday: 19.years.ago) }

      let(:stripe_person) do
        {
          "verification" => { "status" => "verified" }
        }
      end
      let(:stripe_previous_attributes) do
        {
          "verification" => { "status" => "pending" }
        }
      end

      it "does not update guardian verification status" do
        expect {
          described_class.handle_guardian_person_verification_update(
            user, stripe_person, stripe_previous_attributes
          )
        }.not_to change { user_compliance_info.reload.guardian_verification_status }
      end
    end
  end

  describe ".guardian_person_hash" do
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
        guardian_date_of_birth: Date.new(1980, 6, 15),
        country: "United States"
      )
    end

    context "when user is under 18" do
      it "generates correct guardian person hash" do
        hash = described_class.guardian_person_hash(
          user_compliance_info,
          "test_passphrase"
        )

        expect(hash).to include(
          first_name: "John",
          last_name: "Doe",
          email: "guardian@example.com",
          phone: "555-1234"
        )

        expect(hash[:dob]).to include(
          day: 15,
          month: 6,
          year: 1980
        )

        expect(hash[:address]).to include(
          line1: "123 Main St",
          city: "Anytown",
          state: "CA",
          postal_code: "12345",
          country: "US"
        )
      end

      it "includes relationship information" do
        hash = described_class.guardian_person_hash(
          user_compliance_info,
          "test_passphrase"
        )

        expect(hash[:relationship]).to eq({
          representative: true,
          owner: false,
          title: "Legal Guardian"
        })
      end
    end

    context "when user is 18 or older" do
      before { user_compliance_info.update!(birthday: 19.years.ago) }

      it "returns nil" do
        hash = described_class.guardian_person_hash(
          user_compliance_info,
          "test_passphrase"
        )

        expect(hash).to be_nil
      end
    end

    context "when user compliance info is nil" do
      it "returns nil" do
        hash = described_class.guardian_person_hash(
          nil,
          "test_passphrase"
        )

        expect(hash).to be_nil
      end
    end
  end
end
