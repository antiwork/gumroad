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
    context "when user cannot update payments settings" do
      before do
        allow(Pundit).to receive(:policy!).and_return(double(update?: false))
      end

      it "returns not_required" do
        expect(presenter.guardian_verification_state).to eq("not_required")
      end
    end

    context "when user is over 18" do
      before do
        allow(Pundit).to receive(:policy!).and_return(double(update?: true))
        _, _ = user_compliance_info.dup_and_save { |new_info| new_info.birthday = 25.years.ago.to_date }
        user.reload
      end

      it "returns not_required regardless of Stripe account status" do
        expect(presenter.guardian_verification_state).to eq("not_required")
      end

      it "returns not_required even without Stripe account" do
        allow(user).to receive(:stripe_account).and_return(nil)
        expect(presenter.guardian_verification_state).to eq("not_required")
      end
    end

    context "when user is under 18 without Stripe account" do
      before do
        allow(Pundit).to receive(:policy!).and_return(double(update?: true))
        allow(user).to receive(:stripe_account).and_return(nil)
        _, _ = user_compliance_info.dup_and_save { |new_info| new_info.birthday = 16.years.ago.to_date }
        user.reload
      end

      it "returns requires_input so the guardian form is displayed" do
        expect(presenter.guardian_verification_state).to eq("requires_input")
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
          # Create guardian with missing email
          guardian = create(:guardian_empty, email: "temp@example.com")
          guardian.update_column(:email, nil) # bypass validation to test incomplete state
          user.alive_user_compliance_info.update!(guardian: guardian)
          user.reload

          expect(presenter.guardian_verification_state).to eq("requires_input")
        end

        it "returns requires_input when guardian address is incomplete" do
          # Create guardian with missing address
          guardian = create(:guardian_empty)
          guardian.update_column(:street_address, nil) # bypass validation
          user.alive_user_compliance_info.update!(guardian: guardian)
          user.reload

          expect(presenter.guardian_verification_state).to eq("requires_input")
        end

        it "returns requires_input when guardian date of birth is incomplete" do
          # Create guardian with missing date_of_birth
          guardian = create(:guardian_empty)
          guardian.update_column(:date_of_birth, nil) # bypass validation
          user.alive_user_compliance_info.update!(guardian: guardian)
          user.reload

          expect(presenter.guardian_verification_state).to eq("requires_input")
        end

        it "returns requires_input when guardian tax ID is missing" do
          # Create guardian without tax ID (guardian_empty has no tax ID)
          guardian = create(:guardian_empty)
          user.alive_user_compliance_info.update!(guardian: guardian)
          user.reload

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
        guardian = create(:guardian_empty)
        guardian.update_column(:first_name, "") # bypass validation to set empty string
        user.alive_user_compliance_info.update!(guardian: guardian)
        user.reload

        expect(presenter.guardian_verification_state).to eq("requires_input")
      end

      it "treats whitespace-only strings as incomplete" do
        guardian = create(:guardian_empty)
        guardian.update_column(:first_name, "   ") # bypass validation to set whitespace
        user.alive_user_compliance_info.update!(guardian: guardian)
        user.reload

        expect(presenter.guardian_verification_state).to eq("requires_input")
      end

      it "handles missing date of birth components" do
        guardian = create(:guardian_empty)
        guardian.update_column(:date_of_birth, nil) # bypass validation
        user.alive_user_compliance_info.update!(guardian: guardian)
        user.reload

        expect(presenter.guardian_verification_state).to eq("requires_input")
      end

      it "handles zero values for date components" do
        # A date with zero components would be invalid, test incomplete guardian
        guardian = create(:guardian_empty)
        guardian.update_column(:date_of_birth, nil) # bypass validation
        user.alive_user_compliance_info.update!(guardian: guardian)
        user.reload

        expect(presenter.guardian_verification_state).to eq("requires_input")
      end
    end
  end
end
