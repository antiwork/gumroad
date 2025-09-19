# frozen_string_literal: true

require "spec_helper"

describe Settings::PaymentsController, "guardian verification" do
  let(:user) { create(:user) }
  let(:user_compliance_info) { create(:user_compliance_info, user: user) }

  before do
    sign_in user
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

  describe "#show" do
    it "includes guardian information in props" do
      get :show

      expect(response).to be_successful
      expect(assigns(:react_component_props)).to include(
        compliance_info: hash_including(
          guardian_first_name: "John",
          guardian_last_name: "Doe",
          guardian_email: "guardian@example.com",
          guardian_phone: "555-1234",
          guardian_street_address: "123 Main St",
          guardian_city: "Anytown",
          guardian_state: "CA",
          guardian_zip_code: "12345",
          guardian_dob_month: 40.years.ago.month,
          guardian_dob_day: 40.years.ago.day,
          guardian_dob_year: 40.years.ago.year,
          guardian_verification_status: "pending"
        )
      )
    end

    context "when user is 18 or older" do
      before { user_compliance_info.update!(birthday: 19.years.ago) }

      it "includes guardian information as not required" do
        get :show

        expect(response).to be_successful
        expect(assigns(:react_component_props)).to include(
          compliance_info: hash_including(
            guardian_verification_status: "not_required"
          )
        )
      end
    end

    context "when guardian information is incomplete" do
      before do
        user_compliance_info.update!(
          guardian_first_name: "John",
          guardian_last_name: "Doe"
          # Missing other required fields
        )
      end

      it "includes guardian information as incomplete" do
        get :show

        expect(response).to be_successful
        expect(assigns(:react_component_props)).to include(
          compliance_info: hash_including(
            guardian_verification_status: "incomplete"
          )
        )
      end
    end
  end

  describe "#update" do
    let(:update_params) do
      {
        compliance_info: {
          guardian_first_name: "Jane",
          guardian_last_name: "Smith",
          guardian_email: "jane.smith@example.com",
          guardian_phone: "555-9876",
          guardian_street_address: "456 Oak St",
          guardian_city: "Newtown",
          guardian_state: "NY",
          guardian_zip_code: "67890",
          guardian_dob_month: 6,
          guardian_dob_day: 15,
          guardian_dob_year: 1975,
          guardian_stripe_tos_accepted: true,
          guardian_stripe_processing_tos_accepted: true
        }
      }
    end

    context "with valid guardian information" do
      it "updates guardian information" do
        expect {
          patch :update, params: update_params, as: :json
        }.to change { user_compliance_info.reload.guardian_first_name }.to("Jane")
         .and change { user_compliance_info.guardian_last_name }.to("Smith")
         .and change { user_compliance_info.guardian_email }.to("jane.smith@example.com")
         .and change { user_compliance_info.guardian_phone }.to("555-9876")
         .and change { user_compliance_info.guardian_street_address }.to("456 Oak St")
         .and change { user_compliance_info.guardian_city }.to("Newtown")
         .and change { user_compliance_info.guardian_state }.to("NY")
         .and change { user_compliance_info.guardian_zip_code }.to("67890")
         .and change { user_compliance_info.guardian_date_of_birth }.to(Date.new(1975, 6, 15))
      end

      it "returns success with updated props" do
        patch :update, params: update_params, as: :json

        expect(response).to be_successful
        response_data = JSON.parse(response.body)
        expect(response_data["success"]).to be true
        expect(response_data["updated_props"]).to be_present
        expect(response_data["updated_props"]["compliance_info"]).to include(
          "guardian_first_name" => "Jane",
          "guardian_last_name" => "Smith",
          "guardian_email" => "jane.smith@example.com",
          "guardian_phone" => "555-9876",
          "guardian_street_address" => "456 Oak St",
          "guardian_city" => "Newtown",
          "guardian_state" => "NY",
          "guardian_zip_code" => "67890",
          "guardian_dob_month" => 6,
          "guardian_dob_day" => 15,
          "guardian_dob_year" => 1975
        )
      end

      it "triggers guardian verification status update" do
        expect {
          patch :update, params: update_params, as: :json
        }.to change { user_compliance_info.reload.guardian_verification_status }.to("pending")
      end
    end

    context "with invalid guardian information" do
      let(:invalid_params) do
        {
          compliance_info: {
            guardian_first_name: "", # Invalid: empty
            guardian_last_name: "Smith",
            guardian_email: "invalid-email", # Invalid: bad format
            guardian_phone: "555-9876",
            guardian_street_address: "456 Oak St",
            guardian_city: "Newtown",
            guardian_state: "NY",
            guardian_zip_code: "67890",
            guardian_dob_month: 6,
            guardian_dob_day: 15,
            guardian_dob_year: 1975,
            guardian_stripe_tos_accepted: false, # Invalid: not accepted
            guardian_stripe_processing_tos_accepted: true
          }
        }
      end

      it "returns validation errors" do
        patch :update, params: invalid_params, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        response_data = JSON.parse(response.body)
        expect(response_data["success"]).to be false
        expect(response_data["errors"]).to be_present
      end

      it "does not update guardian information" do
        expect {
          patch :update, params: invalid_params, as: :json
        }.not_to change { user_compliance_info.reload.guardian_first_name }
      end
    end

    context "when user is 18 or older" do
      before { user_compliance_info.update!(birthday: 19.years.ago) }

      it "does not require guardian information" do
        patch :update, params: update_params, as: :json

        expect(response).to be_successful
        response_data = JSON.parse(response.body)
        expect(response_data["success"]).to be true
      end
    end
  end

  describe "guardian verification status updates" do
    context "when guardian information becomes complete" do
      let(:complete_params) do
        {
          compliance_info: {
            guardian_first_name: "John",
            guardian_last_name: "Doe",
            guardian_email: "guardian@example.com",
            guardian_phone: "555-1234",
            guardian_street_address: "123 Main St",
            guardian_city: "Anytown",
            guardian_state: "CA",
            guardian_zip_code: "12345",
            guardian_dob_month: 6,
            guardian_dob_day: 15,
            guardian_dob_year: 1980,
            guardian_stripe_tos_accepted: true,
            guardian_stripe_processing_tos_accepted: true
          }
        }
      end

      it "updates status to pending" do
        expect {
          patch :update, params: complete_params, as: :json
        }.to change { user_compliance_info.reload.guardian_verification_status }.to("pending")
      end

      it "triggers background job for Stripe submission" do
        expect {
          patch :update, params: complete_params, as: :json
        }.to have_enqueued_sidekiq_job(SubmitGuardianToStripeWorker).with(user.id)
      end
    end

    context "when guardian information becomes incomplete" do
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

      let(:incomplete_params) do
        {
          compliance_info: {
            guardian_first_name: "", # Remove required field
            guardian_last_name: "Doe",
            guardian_email: "guardian@example.com",
            guardian_phone: "555-1234",
            guardian_street_address: "123 Main St",
            guardian_city: "Anytown",
            guardian_state: "CA",
            guardian_zip_code: "12345",
            guardian_dob_month: 6,
            guardian_dob_day: 15,
            guardian_dob_year: 1980,
            guardian_stripe_tos_accepted: true,
            guardian_stripe_processing_tos_accepted: true
          }
        }
      end

      it "updates status to incomplete" do
        expect {
          patch :update, params: incomplete_params, as: :json
        }.to change { user_compliance_info.reload.guardian_verification_status }.to("incomplete")
      end
    end
  end
end
