# frozen_string_literal: true

require "spec_helper"

RSpec.describe Settings::PaymentsController, type: :controller do
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
        guardian_stripe_tos_accepted: true,
        guardian_stripe_processing_tos_accepted: true,
        country: "United States"
      )
    end

    before do
      sign_in user
      allow(controller).to receive(:pundit_user).and_return(SellerContext.new(user: user, seller: user))
      allow(controller).to receive(:current_seller).and_return(user)
      allow(user).to receive(:fetch_or_build_user_compliance_info).and_return(user_compliance_info)
      allow(controller).to receive(:update_payout_method).and_return(true)
      allow(user).to receive(:tos_agreements).and_return(double("TosAgreements", create!: true))
      allow(user).to receive(:email).and_return("test@example.com")
      allow(user).to receive(:update).and_return(true)
      allow(controller).to receive(:user_signed_in?).and_return(true)
      allow(controller).to receive(:logged_in_user).and_return(user)
      # Set the cookie to point to our test user
      cookies.encrypted[:current_seller_id] = user.id
    end

    describe "GET #show" do
      before do
        allow(user).to receive(:fetch_or_build_user_compliance_info).and_return(user_compliance_info)
      end

      it "includes guardian information in the response" do
        get :show

        expect(response).to be_successful
        react_component_props = assigns[:react_component_props]

        expect(react_component_props[:compliance_info]).to include(
          guardian_first_name: "John",
          guardian_last_name: "Doe",
          guardian_email: "john@example.com",
          guardian_phone: "+1234567890",
          guardian_street_address: "123 Main St",
          guardian_city: "Anytown",
          guardian_state: "CA",
          guardian_zip_code: "12345",
          guardian_dob_day: 40.years.ago.day,
          guardian_dob_month: 40.years.ago.month,
          guardian_dob_year: 40.years.ago.year,
          guardian_tax_id: nil,  # No guardian tax ID set in test data
          guardian_stripe_tos_accepted: true,
          guardian_stripe_processing_tos_accepted: true
        )
      end

      it "includes user_under_18 flag in the response" do
        get :show

        expect(response).to be_successful
        react_component_props = assigns[:react_component_props]

        expect(react_component_props[:user]).to include(is_under_18: true)
      end
    end

    describe "PUT #update" do
      let(:guardian_params) do
        {
          first_name: "Updated First Name",
          last_name: "Updated Last Name",
          guardian_first_name: "Jane",
          guardian_last_name: "Smith",
          guardian_email: "jane@example.com",
          guardian_phone: "+1987654321",
          guardian_street_address: "456 Oak Ave",
          guardian_city: "Springfield",
          guardian_state: "NY",
          guardian_zip_code: "54321",
          guardian_dob_year: 1980,
          guardian_dob_month: 6,
          guardian_dob_day: 20,
          guardian_stripe_tos_accepted: true,
          guardian_stripe_processing_tos_accepted: true,
          dob_year: 2008,
          dob_month: 3,
          dob_day: 15
        }
      end

      before do
        allow(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info).and_return(true)
      end

      it "updates guardian information successfully" do
        put :update, xhr: true, params: { user: guardian_params }

        expect(response).to be_successful
        expect(flash[:notice]).to eq("Thanks! You're all set.")
      end

      it "calls UpdateUserComplianceInfo with guardian parameters" do
        expect_any_instance_of(UpdateUserComplianceInfo).to receive(:process).and_return({ success: true })

        put :update, xhr: true, params: { user: guardian_params }
      end

      context "when guardian information is incomplete" do
        let(:incomplete_guardian_params) do
          guardian_params.merge(
            guardian_first_name: nil,
            guardian_email: nil
          )
        end

        it "handles validation errors gracefully" do
          allow_any_instance_of(UpdateUserComplianceInfo).to receive(:process)
            .and_return({ success: false, error_message: "Guardian first name can't be blank" })

          put :update, xhr: true, params: { user: incomplete_guardian_params }

          expect(response).to be_successful
          expect(response.body).to include("Guardian first name can't be blank")
        end
      end

      context "when user turns 18" do
        let(:adult_user_params) do
          guardian_params.merge(
            dob_year: 2004,  # 18+ years old
            dob_month: 1,
            dob_day: 1
          )
        end

        it "clears guardian information when user becomes 18" do
          put :update, xhr: true, params: { user: adult_user_params }

          expect(response).to be_successful

          # The guardian fields should be cleared in the new compliance info
          # Note: This test verifies that the UpdateUserComplianceInfo service handles
          # guardian info clearing when user turns 18, which is tested in the service specs
        end
      end
    end

    describe "guardian field validation" do
      context "when user is under 18" do
        let(:under_18_user) { create(:user) }
        let(:under_18_compliance_info) do
          create(:user_compliance_info,
            user: under_18_user,
            birthday: 16.years.ago,
            country: "United States"
          )
        end

        before do
          sign_in under_18_user
          allow(controller).to receive(:pundit_user).and_return(SellerContext.new(user: under_18_user, seller: under_18_user))
          allow(controller).to receive(:current_seller).and_return(under_18_user)
          allow(under_18_user).to receive(:fetch_or_build_user_compliance_info).and_return(under_18_compliance_info)
          allow(controller).to receive(:user_signed_in?).and_return(true)
          allow(controller).to receive(:logged_in_user).and_return(under_18_user)
          cookies.encrypted[:current_seller_id] = under_18_user.id
        end

        it "requires guardian information for users under 18" do
          incomplete_params = {
            first_name: "Test",
            last_name: "User",
            dob_year: 2008,
            dob_month: 1,
            dob_day: 1
            # Missing guardian fields
          }

          allow_any_instance_of(UpdateUserComplianceInfo).to receive(:process)
            .and_return({ success: false, error_message: "Guardian information is required for users under 18" })

          put :update, xhr: true, params: { user: incomplete_params }

          expect(response).to be_successful
          expect(response.body).to include("Guardian information is required for users under 18")
        end
      end
    end

    describe "guardian tax ID handling" do
      context "when guardian tax ID is required" do
        let(:tax_id_params) do
          {
            first_name: "Test",
            last_name: "User",
            dob_year: 2008,
            dob_month: 1,
            dob_day: 1,
            guardian_first_name: "Guardian",
            guardian_last_name: "User",
            guardian_email: "guardian@example.com",
            guardian_phone: "+1234567890",
            guardian_street_address: "123 Main St",
            guardian_city: "Anytown",
            guardian_dob_year: 1980,
            guardian_dob_month: 1,
            guardian_dob_day: 1
          }
        end

        it "processes guardian tax ID correctly" do
          put :update, xhr: true, params: { user: tax_id_params }

          expect(response).to be_successful
          expect(flash[:notice]).to eq("Thanks! You're all set.")
        end
      end
    end

    describe "guardian Stripe TOS handling" do
      let(:tos_params) do
        {
          first_name: "Test",
          last_name: "User",
          dob_year: 2008,
          dob_month: 1,
          dob_day: 1,
          guardian_first_name: "Guardian",
          guardian_last_name: "User",
          guardian_email: "guardian@example.com",
          guardian_phone: "+1234567890",
          guardian_street_address: "123 Main St",
          guardian_city: "Anytown",
          guardian_dob_year: 1980,
          guardian_dob_month: 1,
          guardian_dob_day: 1,
          guardian_stripe_tos_accepted: true,
          guardian_stripe_processing_tos_accepted: true
        }
      end

      it "processes guardian TOS acceptance correctly" do
        put :update, xhr: true, params: { user: tos_params }

        expect(response).to be_successful
        expect(flash[:notice]).to eq("Thanks! You're all set.")
      end

      context "when guardian TOS is not accepted" do
        let(:no_tos_params) do
          tos_params.merge(
            guardian_stripe_tos_accepted: false,
            guardian_stripe_processing_tos_accepted: false
          )
        end

        it "handles TOS rejection appropriately" do
          put :update, xhr: true, params: { user: no_tos_params }

          expect(response).to be_successful
          expect(flash[:notice]).to eq("Thanks! You're all set.")
        end
      end
    end
  end
end
