# frozen_string_literal: true

require "spec_helper"

describe "Guardian Verification Flow", type: :integration do
  let(:user) { create(:user) }
  let(:user_compliance_info) { create(:user_compliance_info, user: user) }
  let(:merchant_account) { create(:merchant_account, user: user, charge_processor_id: 'stripe') }

  before do
    user_compliance_info.update!(birthday: 17.years.ago)
  end

  describe "complete guardian verification flow" do
    it "handles the full flow from incomplete to verified" do
      # Step 1: User starts with incomplete guardian information
      expect(user_compliance_info.guardian_verification_status).to eq("incomplete")

      # Step 2: User completes guardian information
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

      # Step 3: Status should be pending and background job should be enqueued
      expect(user_compliance_info.guardian_verification_status).to eq("pending")
      expect(SubmitGuardianToStripeWorker).to have_enqueued_sidekiq_job(user.id)

      # Step 4: Simulate Stripe webhook for verification success
      stripe_person = {
        "verification" => { "status" => "verified" }
      }
      stripe_previous_attributes = {
        "verification" => { "status" => "pending" }
      }

      StripeMerchantAccountManager.handle_guardian_person_verification_update(
        user, stripe_person, stripe_previous_attributes
      )

      # Step 5: Status should be verified
      expect(user_compliance_info.reload.guardian_verification_status).to eq("verified")
    end

    it "handles guardian information updates" do
      # Start with complete guardian information
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

      expect(user_compliance_info.guardian_verification_status).to eq("pending")

      # Update guardian information
      user_compliance_info.update!(
        guardian_first_name: "Jane",
        guardian_email: "jane.doe@example.com"
      )

      # Status should remain pending and new background job should be enqueued
      expect(user_compliance_info.guardian_verification_status).to eq("pending")
      expect(SubmitGuardianToStripeWorker).to have_enqueued_sidekiq_job(user.id)
    end

    it "handles age-out cleanup" do
      # Start with complete guardian information
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
        guardian_stripe_processing_tos_accepted: true,
        guardian_verification_status: "verified"
      )

      # User turns 18
      user_compliance_info.update!(birthday: 19.years.ago)

      # All guardian information should be cleared
      expect(user_compliance_info.reload.guardian_first_name).to be_nil
      expect(user_compliance_info.guardian_last_name).to be_nil
      expect(user_compliance_info.guardian_email).to be_nil
      expect(user_compliance_info.guardian_phone).to be_nil
      expect(user_compliance_info.guardian_street_address).to be_nil
      expect(user_compliance_info.guardian_city).to be_nil
      expect(user_compliance_info.guardian_state).to be_nil
      expect(user_compliance_info.guardian_zip_code).to be_nil
      expect(user_compliance_info.guardian_date_of_birth).to be_nil
      expect(user_compliance_info.guardian_individual_tax_id).to be_nil
      expect(user_compliance_info.guardian_stripe_tos_accepted).to be false
      expect(user_compliance_info.guardian_stripe_processing_tos_accepted).to be false
      expect(user_compliance_info.guardian_verification_status).to eq("not_required")
    end
  end

  describe "webhook integration flow" do
    let(:webhook_payload) do
      {
        id: "evt_guardian_verification_123",
        type: "person.updated",
        account: merchant_account.charge_processor_merchant_id,
        data: {
          object: {
            id: "person_guardian_123",
            relationship: { representative: true, owner: false, title: "Legal Guardian" },
            verification: { status: "verified" }
          },
          previous_attributes: {
            verification: { status: "pending" }
          }
        }
      }
    end

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
        guardian_stripe_processing_tos_accepted: true,
        guardian_verification_status: "pending"
      )
    end

    it "processes guardian verification webhook" do
      # Simulate webhook processing
      event = StripeEventHandler.new(webhook_payload)
      event.handle_stripe_event

      # Guardian verification status should be updated
      expect(user_compliance_info.reload.guardian_verification_status).to eq("verified")
    end

    it "handles guardian verification failure webhook" do
      webhook_payload[:data][:object][:verification][:status] = "unverified"

      # Simulate webhook processing
      event = StripeEventHandler.new(webhook_payload)
      event.handle_stripe_event

      # Guardian verification status should be updated to incomplete
      expect(user_compliance_info.reload.guardian_verification_status).to eq("incomplete")
    end
  end

  describe "frontend integration flow" do
    before do
      sign_in user
    end

    it "provides correct props to frontend" do
      user_compliance_info.update!(
        guardian_first_name: "John",
        guardian_last_name: "Doe",
        guardian_email: "guardian@example.com",
        guardian_phone: "555-1234",
        guardian_street_address: "123 Main St",
        guardian_city: "Anytown",
        guardian_state: "CA",
        guardian_zip_code: "12345",
        guardian_date_of_birth: Date.new(1980, 6, 15),
        guardian_stripe_tos_accepted: true,
        guardian_stripe_processing_tos_accepted: true
      )

      get "/settings/payments"

      expect(response).to be_successful
      expect(assigns(:react_component_props)[:compliance_info]).to include(
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
        guardian_verification_status: "pending"
      )
    end

    it "updates guardian information via API" do
      update_params = {
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

      patch "/settings/payments", params: update_params, as: :json

      expect(response).to be_successful
      response_data = JSON.parse(response.body)
      expect(response_data["success"]).to be true
      expect(response_data["updated_props"]).to be_present

      # Verify the update was applied
      expect(user_compliance_info.reload.guardian_first_name).to eq("Jane")
      expect(user_compliance_info.guardian_last_name).to eq("Smith")
      expect(user_compliance_info.guardian_email).to eq("jane.smith@example.com")
      expect(user_compliance_info.guardian_verification_status).to eq("pending")
    end
  end

  describe "error handling flow" do
    it "handles Stripe API failures gracefully" do
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

      # Simulate Stripe API failure
      allow(Stripe::Account).to receive(:create_person).and_raise(Stripe::StripeError.new("API Error"))

      expect {
        SubmitGuardianToStripeWorker.new.perform(user.id)
      }.to raise_error(Stripe::StripeError)

      # Status should remain pending (not updated to incomplete due to error)
      expect(user_compliance_info.reload.guardian_verification_status).to eq("pending")
    end

    it "handles missing user gracefully" do
      expect {
        SubmitGuardianToStripeWorker.new.perform(99999)
      }.not_to raise_error
    end

    it "handles missing compliance info gracefully" do
      user_compliance_info.destroy!

      expect {
        SubmitGuardianToStripeWorker.new.perform(user.id)
      }.not_to raise_error
    end

    it "handles missing merchant account gracefully" do
      merchant_account.destroy!

      expect {
        SubmitGuardianToStripeWorker.new.perform(user.id)
      }.not_to raise_error
    end
  end
end
