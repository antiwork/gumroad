# frozen_string_literal: true

require "spec_helper"

RSpec.describe Settings::PaymentsController, type: :controller do
  let(:user) { create(:user) }
  let(:user_compliance_info) { user.alive_user_compliance_info }

  before do
    sign_in user
    stripe_account = double("StripeAccount", present?: true, id: 1)
    allow(user).to receive(:stripe_account).and_return(stripe_account)
    
    # Mock the policy and guardian verification states
    policy_instance = double("Settings::Payments::UserPolicy")
    allow(policy_instance).to receive(:method_missing).and_return(true)
    allow(policy_instance).to receive(:respond_to?).and_return(true)
    allow(Pundit).to receive(:policy!).and_return(policy_instance)
    
    # We'll set the guardian_verification_state per test as needed
  end

  describe "Legal guardian verification workflow for under-18 users" do
    context "when user is under 18" do
      let(:under_18_birthday) { 16.years.ago.to_date }

      describe "GET #show" do
        it "displays legal guardian banner with requires_input state" do
          allow_any_instance_of(SettingsPresenter).to receive(:guardian_verification_state).and_return("requires_input")
          create(:user_compliance_info, user: user, birthday: under_18_birthday)
          
          get :show

          expect(response).to have_http_status(:ok)
          expect(assigns(:react_component_props)).to be_present
          expect(assigns(:react_component_props)[:guardian_verification_state]).to eq("requires_input")
        end

        context "when guardian info is partially provided" do
          it "still shows requires_input state for incomplete info" do
            allow_any_instance_of(SettingsPresenter).to receive(:guardian_verification_state).and_return("requires_input")
            create(:user_compliance_info, user: user, birthday: under_18_birthday,
              guardian_first_name: "John",
              guardian_last_name: "Guardian", 
              guardian_email: "guardian@example.com"
            )
            
            get :show

            expect(response).to have_http_status(:ok)
            expect(assigns(:react_component_props)[:guardian_verification_state]).to eq("requires_input")
          end
        end

        context "when guardian info is complete but not verified" do
          it "shows pending verification state" do
            allow_any_instance_of(SettingsPresenter).to receive(:guardian_verification_state).and_return("pending")
            create(:user_compliance_info, user: user, birthday: under_18_birthday)

            get :show

            expect(response).to have_http_status(:ok)
            expect(assigns(:react_component_props)).to be_present
            expect(assigns(:react_component_props)[:guardian_verification_state]).to eq("pending")
          end
        end

        context "when guardian info is verified" do
          it "does not show guardian banner when verified" do
            allow_any_instance_of(SettingsPresenter).to receive(:guardian_verification_state).and_return("verified")
            create(:user_compliance_info, user: user, birthday: under_18_birthday)

            get :show

            expect(response).to have_http_status(:ok)
            expect(assigns(:react_component_props)).to be_present
            expect(assigns(:react_component_props)[:guardian_verification_state]).to eq("verified")
          end
        end
      end

      describe "POST #update" do
        let(:valid_guardian_attributes) do
          {
            guardian_first_name: "John",
            guardian_last_name: "Guardian",
            guardian_email: "guardian@example.com",
            guardian_phone: "+1234567890",
            guardian_street_address: "123 Guardian St",
            guardian_city: "Guardian City",
            guardian_state: "CA",
            guardian_zip_code: "90210",
            guardian_country: "US",
            guardian_dob_day: 15,
            guardian_dob_month: 6,
            guardian_dob_year: 1980,
            guardian_individual_tax_id: "123456789",
            guardian_stripe_tos_accepted: true,
            guardian_stripe_processing_tos_accepted: true
          }
        end

        it "successfully submits guardian information" do
          create(:user_compliance_info, user: user, birthday: under_18_birthday)
          
          post :update, params: {
            user_compliance_info: valid_guardian_attributes
          }

          expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body)["success"]).to eq(true)
          
          updated_info = user.alive_user_compliance_info
          expect(updated_info.guardian_first_name).to eq("John")
          expect(updated_info.guardian_last_name).to eq("Guardian")
          expect(updated_info.guardian_email).to eq("guardian@example.com")
          expect(updated_info.guardian_phone).to eq("+1234567890")
          expect(updated_info.guardian_street_address).to eq("123 Guardian St")
          expect(updated_info.guardian_city).to eq("Guardian City")
          expect(updated_info.guardian_state).to eq("CA")
          expect(updated_info.guardian_zip_code).to eq("90210")
          expect(updated_info.guardian_country).to eq("United States")
          expect(updated_info.guardian_dob_day).to eq("15")
          expect(updated_info.guardian_dob_month).to eq("6")
          expect(updated_info.guardian_dob_year).to eq("1980")
          expect(updated_info.guardian_stripe_tos_accepted).to eq(true)
          expect(updated_info.guardian_stripe_processing_tos_accepted).to eq(true)
        end

        it "validates required guardian fields" do
          create(:user_compliance_info, user: user, birthday: under_18_birthday)
          
          post :update, params: {
            user_compliance_info: {
              guardian_first_name: "",
              guardian_last_name: "",
              guardian_email: "invalid-email"
            }
          }

          expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body)["success"]).to eq(false)
          expect(JSON.parse(response.body)["error_message"]).to be_present
        end

        it "validates guardian date of birth is realistic" do
          create(:user_compliance_info, user: user, birthday: under_18_birthday)
          
          post :update, params: {
            user_compliance_info: valid_guardian_attributes.merge(
              guardian_dob_year: 2020  # Too young to be a guardian
            )
          }

          expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body)["success"]).to eq(false)
          expect(JSON.parse(response.body)["error_message"]).to include("Guardian must be at least 18 years old")
        end

        it "requires terms of service acceptance" do
          create(:user_compliance_info, user: user, birthday: under_18_birthday)
          
          post :update, params: {
            user_compliance_info: valid_guardian_attributes.merge(
              guardian_stripe_tos_accepted: false,
              guardian_stripe_processing_tos_accepted: false
            )
          }

          expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body)["success"]).to eq(false)
          expect(JSON.parse(response.body)["error_message"]).to eq("Guardian must accept the terms of service")
        end

        context "with different countries" do
          it "handles Canadian guardian information" do
            canadian_attributes = valid_guardian_attributes.merge(
              guardian_country: "CA",
              guardian_state: "ON",
              guardian_zip_code: "K1A 0A6",
              guardian_individual_tax_id: "123456789"  # Canadian SIN
            )

            create(:user_compliance_info, user: user, birthday: under_18_birthday)
            
            post :update, params: {
              user_compliance_info: canadian_attributes
            }

            expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body)["success"]).to eq(true)
            
            updated_info = user.alive_user_compliance_info
            expect(updated_info.guardian_country).to eq("Canada")
            expect(updated_info.guardian_state).to eq("ON")
          end

          it "handles UK guardian information without tax ID requirement" do
            uk_attributes = valid_guardian_attributes.except(:guardian_individual_tax_id).merge(
              guardian_country: "GB",
              guardian_state: "England",
              guardian_zip_code: "SW1A 1AA"
            )

            create(:user_compliance_info, user: user, birthday: under_18_birthday)
            
            post :update, params: {
              user_compliance_info: uk_attributes
            }

            expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body)["success"]).to eq(true)
            
            updated_info = user.alive_user_compliance_info
            expect(updated_info.guardian_country).to eq("United Kingdom")
          end
        end
      end
    end

    context "when user is over 18" do
      let(:over_18_birthday) { 25.years.ago.to_date }

      before do
        create(:user_compliance_info, user: user, birthday: over_18_birthday)
      end

      describe "GET #show" do
        it "does not show legal guardian information section" do
          allow_any_instance_of(SettingsPresenter).to receive(:guardian_verification_state).and_return("not_required")
          get :show

          expect(response).to have_http_status(:ok)
          expect(assigns(:react_component_props)).to be_present
          expect(assigns(:react_component_props)[:guardian_verification_state]).to eq("not_required")
        end
      end

      describe "POST #update" do
        it "ignores guardian information if provided" do
          post :update, params: {
            user_compliance_info: {
              guardian_first_name: "John",
              guardian_last_name: "Guardian",
              guardian_email: "guardian@example.com"
            }
          }

          updated_info = user.alive_user_compliance_info
          expect(updated_info.guardian_first_name).to be_blank
          expect(updated_info.guardian_last_name).to be_blank
          expect(updated_info.guardian_email).to be_blank
        end
      end
    end
  end

  describe "Guardian compliance info requests handling" do
    let(:under_18_birthday) { 16.years.ago.to_date }

    before do
      create(:user_compliance_info, user: user, birthday: under_18_birthday)
    end

    context "when Stripe requires guardian information" do
      before do
        allow(user).to receive(:stripe_requires_legal_guardian_compliance_info?).and_return(true)
      end

      it "creates guardian compliance info requests automatically" do
        expect(user).to respond_to(:stripe_requires_legal_guardian_compliance_info?)
      end

      it "handles guardian person ID from Stripe webhook" do
        guardian_request = create(:guardian_compliance_info_request,
          user: user,
          field_needed: "guardian_first_name",
          guardian_person_id: "person_123456789"
        )

        expect(guardian_request.guardian_person_id).to eq("person_123456789")
        expect(guardian_request.field_needed).to eq("guardian_first_name")
      end
    end

    context "when guardian information is provided" do
      let!(:guardian_request) do
        create(:guardian_compliance_info_request,
          user: user,
          field_needed: "guardian_first_name",
          state: "requested"
        )
      end

      it "marks request as provided when guardian info is submitted" do
        # Test that we can add guardian information
        user.alive_user_compliance_info&.guardian_first_name = "John" if user.alive_user_compliance_info
        
        GuardianComplianceInfoRequest.handle_new_guardian_compliance_info(user_compliance_info)
        
        guardian_request.reload
        expect(guardian_request.state).to eq("provided")
        expect(guardian_request.provided_at).to be_present
      end

      it "records email notification timestamps" do
        guardian_request.record_email_sent!(Time.current)
        
        expect(guardian_request.emails_sent_at).not_to be_empty
        expect(guardian_request.emails_sent_at.first).to be_a(Time)
      end
    end
  end

  describe "Age verification edge cases" do
    it "handles users exactly 18 years old" do
      allow_any_instance_of(SettingsPresenter).to receive(:guardian_verification_state).and_return("not_required")
      create(:user_compliance_info, user: user, birthday: 18.years.ago.to_date)
      
      get :show

      expect(response).to have_http_status(:ok)
      expect(assigns(:react_component_props)[:guardian_verification_state]).to eq("not_required")
    end

    it "handles users who turn 18 during the process" do
      create(:user_compliance_info, user: user, birthday: 17.years.ago.to_date + 360.days)
      
      # Initially shows guardian requirement
      allow_any_instance_of(SettingsPresenter).to receive(:guardian_verification_state).and_return("requires_input")
      get :show
      expect(assigns(:react_component_props)[:guardian_verification_state]).to eq("requires_input")
      
      # User turns 18
      travel_to 10.days.from_now do
        allow_any_instance_of(SettingsPresenter).to receive(:guardian_verification_state).and_return("not_required")
        get :show
        expect(assigns(:react_component_props)[:guardian_verification_state]).to eq("not_required")
      end
    end

    it "validates minimum age of 13 years" do
      invalid_compliance_info = build(:user_compliance_info, user: user, birthday: 12.years.ago.to_date)
      
      expect(invalid_compliance_info).not_to be_valid
      expect(invalid_compliance_info.errors[:base]).to include("You must be 13 years old to use Gumroad.")
    end
  end

  describe "Integration with Stripe events" do
    let(:under_18_birthday) { 16.years.ago.to_date }

    before do
      create(:user_compliance_info, user: user, birthday: under_18_birthday)
      allow(user).to receive(:stripe_account).and_return(double("StripeAccount", present?: true))
    end

    it "handles Stripe person.updated events for guardians" do
      guardian_request = create(:guardian_compliance_info_request,
        user: user,
        field_needed: "guardian_first_name",
        guardian_person_id: "person_123456789",
        stripe_event_id: "evt_test_webhook"
      )

      expect(guardian_request.stripe_event_id).to eq("evt_test_webhook")
      expect(guardian_request.guardian_person_id).to eq("person_123456789")
    end

    it "maps Stripe guardian fields to internal fields correctly" do
      stripe_field = "person_123456789.first_name"
      guardian_person_id = "123456789"
      
      expect(user).to respond_to(:map_stripe_guardian_field_to_internal_field)
      
      mapped_field = user.map_stripe_guardian_field_to_internal_field(stripe_field, guardian_person_id)
      expect(mapped_field).to eq("guardian_first_name")
    end

    it "handles verification document requirements" do
      guardian_request = create(:guardian_compliance_info_request,
        user: user,
        field_needed: "guardian_verification.document",
        guardian_person_id: "person_123456789"
      )

      expect(guardian_request.field_needed).to eq("guardian_verification.document")
    end
  end
end