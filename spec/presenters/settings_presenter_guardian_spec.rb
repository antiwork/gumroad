# frozen_string_literal: true

require "spec_helper"

RSpec.describe SettingsPresenter, type: :presenter do
  let(:user) { create(:user_with_compliance_info) }
  let(:pundit_user) { SellerContext.new(user: user, seller: user) }
  let(:presenter) { described_class.new(pundit_user: pundit_user) }
  let(:user_compliance_info) { user.alive_user_compliance_info }

  before do
    allow(user).to receive(:stripe_account).and_return(build(:merchant_account))
  end

  describe "#guardian_verification_state" do
    context "when user has no Stripe account" do
      before do
        allow(user).to receive(:stripe_account).and_return(nil)
      end

      it "returns not_required" do
        expect(presenter.guardian_verification_state).to eq("not_required")
      end
    end

    context "when user cannot update payments settings" do
      before do
        allow(Pundit).to receive(:policy!).and_return(double(update?: false))
      end

      it "returns not_required" do
        expect(presenter.guardian_verification_state).to eq("not_required")
      end
    end

    context "when user has Stripe account and update permissions" do
      before do
        allow(Pundit).to receive(:policy!).and_return(double(update?: true))
        # Set user as under 18 for guardian verification scenarios
        _, _ = user_compliance_info.dup_and_save { |new_info| new_info.birthday = 16.years.ago.to_date }
        user.reload
      end

      context "with no guardian compliance requests" do
        it "returns requires_input" do
          expect(presenter.guardian_verification_state).to eq("requires_input")
        end
      end

      context "with incomplete guardian information" do
        before do
          create(:user_compliance_info_request, user: user, field_needed: "guardian_first_name")
        end

        it "returns requires_input when guardian first name is missing" do
          expect(presenter.guardian_verification_state).to eq("requires_input")
        end

        it "returns requires_input when guardian email is missing" do
          _, _ = user_compliance_info.dup_and_save do |new_info|
            new_info.guardian_first_name = "John"
            new_info.guardian_last_name = "Guardian"
          end

          expect(presenter.guardian_verification_state).to eq("requires_input")
        end

        it "returns requires_input when guardian address is incomplete" do
          _, _ = user_compliance_info.dup_and_save do |new_info|
            new_info.guardian_first_name = "John"
            new_info.guardian_last_name = "Guardian"
            new_info.guardian_email = "guardian@example.com"
            new_info.guardian_phone = "+1234567890"
          end

          expect(presenter.guardian_verification_state).to eq("requires_input")
        end

        it "returns requires_input when guardian date of birth is incomplete" do
          _, _ = user_compliance_info.dup_and_save do |new_info|
            new_info.guardian_first_name = "John"
            new_info.guardian_last_name = "Guardian"
            new_info.guardian_email = "guardian@example.com"
            new_info.guardian_phone = "+1234567890"
            new_info.guardian_street_address = "123 Guardian St"
            new_info.guardian_city = "Guardian City"
            new_info.guardian_state = "CA"
            new_info.guardian_zip_code = "90210"
            new_info.guardian_country = "United States"
            new_info.guardian_dob_day = 15
            new_info.guardian_dob_month = 6
          end

          expect(presenter.guardian_verification_state).to eq("requires_input")
        end

        it "returns requires_input when guardian tax ID is missing" do
          _, _ = user_compliance_info.dup_and_save do |new_info|
            new_info.guardian_first_name = "John"
            new_info.guardian_last_name = "Guardian"
            new_info.guardian_email = "guardian@example.com"
            new_info.guardian_phone = "+1234567890"
            new_info.guardian_street_address = "123 Guardian St"
            new_info.guardian_city = "Guardian City"
            new_info.guardian_state = "CA"
            new_info.guardian_zip_code = "90210"
            new_info.guardian_country = "United States"
            new_info.guardian_dob_day = 15
            new_info.guardian_dob_month = 6
            new_info.guardian_dob_year = 1980
          end

          expect(presenter.guardian_verification_state).to eq("requires_input")
        end
      end
    end
  end

  describe "#payments_props" do
    let(:remote_ip) { "192.168.1.1" }

    context "for user under 18" do
      before do
        _, _ = user_compliance_info.dup_and_save { |new_info| new_info.birthday = 16.years.ago.to_date }
        user.reload
      end

      it "includes guardian verification state in props" do
        props = presenter.payments_props(remote_ip: remote_ip)

        expect(props[:guardian_verification_state]).to eq("requires_input")
      end
    end

    context "for user over 18" do
      before do
        _, _ = user_compliance_info.dup_and_save { |new_info| new_info.birthday = 25.years.ago.to_date }
        user.reload
      end

      it "includes not_required state in props" do
        props = presenter.payments_props(remote_ip: remote_ip)

        expect(props[:guardian_verification_state]).to eq("not_required")
      end
    end
  end

  describe "guardian information completeness logic" do
    context "edge cases for completeness check" do
      before do
        allow(user).to receive(:stripe_account).and_return(build(:merchant_account))
        allow(Pundit).to receive(:policy!).and_return(double(update?: true))
        # Set user as under 18 for guardian scenarios
        _, _ = user_compliance_info.dup_and_save { |new_info| new_info.birthday = 16.years.ago.to_date }
        user.reload
        create(:user_compliance_info_request, user: user, field_needed: "guardian_first_name")
      end

      it "handles nil compliance info gracefully" do
        # Even with nil compliance info, if user has requests, we need to check age from the database
        # But with nil compliance info, under_18? will return false, so it should be "not_required"
        allow(user).to receive(:alive_user_compliance_info).and_return(nil)

        expect(presenter.guardian_verification_state).to eq("not_required")
      end

      it "treats empty strings as incomplete" do
        _, _ = user_compliance_info.dup_and_save do |new_info|
          new_info.guardian_first_name = ""
          new_info.guardian_last_name = "Guardian"
          new_info.guardian_email = "guardian@example.com"
          new_info.guardian_phone = "+1234567890"
          new_info.guardian_street_address = "123 Guardian St"
          new_info.guardian_city = "Guardian City"
          new_info.guardian_state = "CA"
          new_info.guardian_zip_code = "90210"
          new_info.guardian_country = "United States"
          new_info.guardian_dob_day = 15
          new_info.guardian_dob_month = 6
          new_info.guardian_dob_year = 1980
          new_info.guardian_individual_tax_id = "123456789"
        end

        expect(presenter.guardian_verification_state).to eq("requires_input")
      end

      it "treats whitespace-only strings as incomplete" do
        _, _ = user_compliance_info.dup_and_save do |new_info|
          new_info.guardian_first_name = "   "
          new_info.guardian_last_name = "Guardian"
          new_info.guardian_email = "guardian@example.com"
          new_info.guardian_phone = "+1234567890"
          new_info.guardian_street_address = "123 Guardian St"
          new_info.guardian_city = "Guardian City"
          new_info.guardian_state = "CA"
          new_info.guardian_zip_code = "90210"
          new_info.guardian_country = "United States"
          new_info.guardian_dob_day = 15
          new_info.guardian_dob_month = 6
          new_info.guardian_dob_year = 1980
          new_info.guardian_individual_tax_id = "123456789"
        end

        expect(presenter.guardian_verification_state).to eq("requires_input")
      end

      it "handles missing date of birth components" do
        _, _ = user_compliance_info.dup_and_save do |new_info|
          new_info.guardian_first_name = "John"
          new_info.guardian_last_name = "Guardian"
          new_info.guardian_email = "guardian@example.com"
          new_info.guardian_phone = "+1234567890"
          new_info.guardian_street_address = "123 Guardian St"
          new_info.guardian_city = "Guardian City"
          new_info.guardian_state = "CA"
          new_info.guardian_zip_code = "90210"
          new_info.guardian_country = "United States"
          new_info.guardian_dob_day = nil
          new_info.guardian_dob_month = 6
          new_info.guardian_dob_year = 1980
          new_info.guardian_individual_tax_id = "123456789"
        end

        expect(presenter.guardian_verification_state).to eq("requires_input")
      end

      it "handles zero values for date components" do
        _, _ = user_compliance_info.dup_and_save do |new_info|
          new_info.guardian_first_name = "John"
          new_info.guardian_last_name = "Guardian"
          new_info.guardian_email = "guardian@example.com"
          new_info.guardian_phone = "+1234567890"
          new_info.guardian_street_address = "123 Guardian St"
          new_info.guardian_city = "Guardian City"
          new_info.guardian_state = "CA"
          new_info.guardian_zip_code = "90210"
          new_info.guardian_country = "United States"
          new_info.guardian_dob_day = 0
          new_info.guardian_dob_month = 6
          new_info.guardian_dob_year = 1980
          new_info.guardian_individual_tax_id = "123456789"
        end

        expect(presenter.guardian_verification_state).to eq("requires_input")
      end
    end
  end
end
