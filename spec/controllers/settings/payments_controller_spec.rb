# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Settings::PaymentsController, :vcr do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  before :each do
    create(:user_compliance_info, country: "United States", user: seller)
    allow_any_instance_of(User).to receive(:external_id).and_return("6")
  end

  before do
    sign_in seller
  end

  context "when logged in user is admin of seller account" do
    include_context "with user signed in as admin for seller"

    it_behaves_like "authorize called for controller", Settings::Payments::UserPolicy do
      let(:record) { seller }
    end
  end

  describe "GET show" do
    include_context "with user signed in as admin for seller"

    before do
      seller.check_merchant_account_is_linked = true
      seller.save!
    end

    it "returns http success and assigns correct instance variables" do
      get :show

      expect(response).to be_successful
      react_component_props = assigns[:react_component_props]
      expect(react_component_props[:user][:country_code]).to eq("US")
    end

    it "assigns oauth_authorizations" do
      get :show
      expect(assigns(:stripe_authorization))
      expect(assigns(:paypal_authorization))
    end
  end

  describe "PUT update" do
    let(:user) { seller }

    before do
      create(:user_compliance_info_empty, country: "United States", user:)
    end

    let(:params) do
      {
        first_name: "barnabas",
        last_name: "barnabastein",
        street_address: "123 barnabas st",
        city: "barnabasville",
        state: "NY",
        zip_code: "94104",
        dba: "barnie",
        is_business: "off",
        ssn_last_four: "6789",
        dob_month: "3",
        dob_day: "4",
        dob_year: "1955",
        phone: "+1#{GUMROAD_MERCHANT_DESCRIPTOR_PHONE_NUMBER.tr("()-", "")}",
      }
    end

    let!(:request_1) { create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::LegalEntity::Address::STREET) }
    let!(:request_2) { create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Business::Address::STREET) }
    let!(:request_3) { create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::Address::STREET) }
    let!(:request_4) { create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Business::TAX_ID) }

    before do
      allow(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info).and_return(true)
    end

    def expect_save_success_flash_message
      expect(flash[:notice]).to eq("Thanks! You're all set.")
    end

    describe "tos" do
      describe "with terms notice displayed" do
        describe "with time" do
          let(:time_freeze) { Time.zone.local(2015, 4, 1) }

          it "updates the tos last agreed at" do
            travel_to(time_freeze) do
              put :update, xhr: true, params: { user: params, terms_accepted: true }
            end
            user.reload
            expect(user.tos_agreements.last.created_at).to eq(time_freeze)
          end
        end

        describe "with ip" do
          let(:ip) { "54.234.242.13" }

          before do
            @request.remote_ip = ip
          end

          it "updates the tos last agreed ip" do
            put :update, xhr: true, params: { user: params, terms_accepted: true }
            user.reload
            expect(user.tos_agreements.last.ip).to eq(ip)
          end
        end
      end
    end

    it "updates payouts_paused_by_user" do
      expect do
        put :update, params: { payouts_paused_by_user: true }
      end.to change { user.reload.payouts_paused_by_user }.from(false).to(true)
    end

    describe "minimum payout threshold" do
      it "updates the payout threshold for valid amounts" do
        expect do
          put :update, params: { payout_threshold_cents: 2000 }, as: :json
        end.to change { user.reload.payout_threshold_cents }.from(1000).to(2000)

        expect(response.parsed_body["success"]).to be(true)
      end

      it "returns an error for invalid amounts" do
        put :update, params: { payout_threshold_cents: 500 }, as: :json

        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error_message"]).to eq("Your payout threshold must be greater than the minimum payout amount")
        expect(user.reload.payout_threshold_cents).to eq(1000)
      end
    end

    describe "payout frequency" do
      it "updates the payout frequency for valid values" do
        expect do
          put :update, params: { payout_frequency: User::PayoutSchedule::MONTHLY }, as: :json
        end.to change { user.reload.payout_frequency }.from(User::PayoutSchedule::WEEKLY).to(User::PayoutSchedule::MONTHLY)

        expect(response.parsed_body["success"]).to be(true)
      end

      it "returns an error for invalid values" do
        put :update, params: { payout_frequency: "invalid" }, as: :json

        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error_message"]).to eq("Payout frequency must be daily, weekly, monthly, or quarterly")
        expect(user.reload.payout_frequency).to eq(User::PayoutSchedule::WEEKLY)
      end
    end

    describe "individual" do
      let(:all_params) do { user: params }.merge!(
        bank_account: {
          type: AchAccount.name,
          account_number: "000123456789",
          account_number_confirmation: "000123456789",
          routing_number: "110000000",
          account_holder_full_name: "gumbot"
        }
      ) end
      it "updates the compliance information and return the proper response" do
        put :update, xhr: true, params: all_params
        compliance_info = user.fetch_or_build_user_compliance_info
        expect(compliance_info.first_name).to eq "barnabas"
        expect(compliance_info.last_name).to eq "barnabastein"
        expect(compliance_info.street_address).to eq "123 barnabas st"
        expect(compliance_info.city).to eq "barnabasville"
        expect(compliance_info.state).to eq "NY"
        expect(compliance_info.zip_code).to eq "94104"
        expect(compliance_info.phone).to eq "+1#{GUMROAD_MERCHANT_DESCRIPTOR_PHONE_NUMBER.tr("()-", "")}"
        expect(compliance_info.is_business).to be(false)
        expect(compliance_info.individual_tax_id.decrypt("1234")).to eq "6789"

        expect(response.parsed_body["success"]).to be(true)
      end

      it "does not overwrite information for steps that the ui did not provide" do
        put :update, xhr: true, params: all_params
        put :update, xhr: true, params: { user: { first_name: "newfirst", last_name: "newlast" } }
        compliance_info = user.fetch_or_build_user_compliance_info
        expect(compliance_info.first_name).to eq "newfirst"
        expect(compliance_info.last_name).to eq "newlast"
        expect(compliance_info.street_address).to eq "123 barnabas st"
        expect(compliance_info.city).to eq "barnabasville"
        expect(compliance_info.state).to eq "NY"
        expect(compliance_info.zip_code).to eq "94104"
        expect(compliance_info.is_business).to be(false)

        expect(response.parsed_body["success"]).to be(true)
      end

      it "does not overwrite information for steps that the ui did provide as blank" do
        put :update, xhr: true, params: all_params
        put :update, xhr: true, params: { user: { first_name: "newfirst", last_name: "newlast", individual_tax_id: "" } }
        compliance_info = user.fetch_or_build_user_compliance_info
        expect(compliance_info.first_name).to eq "newfirst"
        expect(compliance_info.last_name).to eq "newlast"
        expect(compliance_info.individual_tax_id).to be_present
        expect(compliance_info.individual_tax_id.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))).to be_present

        expect(response.parsed_body["success"]).to be(true)
      end

      it "clears only the requests that are present" do
        put :update, xhr: true, params: all_params
        put :update, xhr: true, params: { user: { first_name: "newfirst", last_name: "newlast" } }
        request_1.reload
        request_2.reload
        request_3.reload
        request_4.reload
        expect(request_1.state).to eq("provided")
        expect(request_2.state).to eq("requested")
        expect(request_3.state).to eq("provided")
        expect(request_4.state).to eq("requested")
      end

      describe "immediate stripe account creation" do
        let(:all_params) { { user: params } }

        describe "user has a bank account, and a merchant account already" do
          before do
            all_params.merge!(
              bank_account: {
                type: AchAccount.name,
                account_number: "000123456789",
                account_number_confirmation: "000123456789",
                routing_number: "110000000",
                account_holder_full_name: "gumbot"
              }
            )
            create(:merchant_account, user:)
          end

          it "does not try to create a new stripe account because user already has one" do
            expect(StripeMerchantAccountManager).not_to receive(:create_account)

            put :update, xhr: true, params: all_params

            expect(response.parsed_body["success"]).to be(true)
          end
        end

        describe "user does not have a bank account, or a merchant account" do
          it "does not try to create a new stripe account because user does not have a bank account" do
            expect(StripeMerchantAccountManager).not_to receive(:create_account)

            put :update, xhr: true, params: all_params

            expect(response.parsed_body["success"]).to be(true)
          end
        end

        describe "user has a bank account but not a merchant account" do
          it "creates a new stripe merchant account for the user" do
            all_params.merge!(
              bank_account: {
                type: AchAccount.name,
                account_number: "000123456789",
                account_number_confirmation: "000123456789",
                routing_number: "110000000",
                account_holder_full_name: "gumbot"
              }
            )

            expect(StripeMerchantAccountManager).to receive(:create_account).with(user, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")).and_call_original

            put :update, xhr: true, params: all_params

            expect(user.reload.stripe_account).to be_present
            expect(response.parsed_body["success"]).to be(true)
          end

          it "raises error if stripe account creation fails" do
            all_params.merge!(
              bank_account: {
                type: AchAccount.name,
                account_number: "123123123",
                account_number_confirmation: "123123123",
                routing_number: "110000000",
                account_holder_full_name: "gumbot"
              }
            )

            expect(StripeMerchantAccountManager).to receive(:create_account).with(user, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")).and_call_original

            put :update, xhr: true, params: all_params

            expect(user.reload.stripe_account).to be_nil
            expect(response.parsed_body["success"]).to be(false)
            expect(response.parsed_body["error_message"]).to eq("You must use a test bank account number in test mode. Try 000123456789 or see more options at https://stripe.com/docs/connect/testing#account-numbers.")
          end
        end
      end

      describe "user enters a birthday accidentally that is under 13 years old given todays date" do
        before do
          put :update, xhr: true, params: { user: params }
          params.merge!(
            dob_month: "1",
            dob_day: "1",
            dob_year: Time.current.year.to_s
          )
        end

        it "returns an error" do
          put :update, xhr: true, params: { user: params }
          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["error_message"]).to eq("You must be 13 years old to use Gumroad.")
        end

        it "leaves the previous user compliance info data unchanged" do
          old_user_compliance_info_id = user.alive_user_compliance_info.id
          old_user_compliance_info_birthday = user.alive_user_compliance_info.birthday
          put :update, xhr: true, params: { user: params }
          expect(user.alive_user_compliance_info.id).to eq(old_user_compliance_info_id)
          expect(user.alive_user_compliance_info.birthday).to eq(old_user_compliance_info_birthday)
        end
      end

      describe "creator enters an invalid zip code" do
        before do
          params.merge!(
            business_zip_code: "9410494104",
          )
        end

        it "returns an error response" do
          put :update, xhr: true, params: { user: params }
          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["error_message"]).to eq("You entered a ZIP Code that doesn't exist within your country.")
        end
      end

      describe "user is verified" do
        before do
          put :update, xhr: true, params: { user: params }
          user.merchant_accounts << create(:merchant_account, charge_processor_verified_at: Time.current)
        end

        describe "user saves existing data unchanged" do
          before do
            put :update, xhr: true, params: { user: params }
          end

          it "returns success" do
            expect(response.parsed_body["success"]).to be(true)
          end

          it "the users current compliance info should contain the same data" do
            compliance_info = user.fetch_or_build_user_compliance_info
            expect(compliance_info.first_name).to eq "barnabas"
            expect(compliance_info.last_name).to eq "barnabastein"
            expect(compliance_info.street_address).to eq "123 barnabas st"
            expect(compliance_info.city).to eq "barnabasville"
            expect(compliance_info.state).to eq "NY"
            expect(compliance_info.zip_code).to eq "94104"
            expect(compliance_info.is_business).to be(false)
            expect(compliance_info.individual_tax_id.decrypt("1234")).to eq "6789"
          end
        end

        describe "user wishes to edit a frozen field (e.g. first name)" do
          before do
            error_message = "Invalid request: You cannot change legal_entity[first_name] via API if an account is verified."
            allow(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info).and_raise(Stripe::InvalidRequestError.new(error_message, nil))
            params.merge!(first_name: "barny")
            put :update, xhr: true, params: { user: params }
          end

          it "returns an error" do
            expect(response.parsed_body["success"]).to be(false)
          end

          it "the users current compliance info should be changed" do
            compliance_info = user.fetch_or_build_user_compliance_info
            expect(compliance_info.first_name).to eq "barny"
            expect(compliance_info.last_name).to eq "barnabastein"
            expect(compliance_info.street_address).to eq "123 barnabas st"
            expect(compliance_info.city).to eq "barnabasville"
            expect(compliance_info.state).to eq "NY"
            expect(compliance_info.zip_code).to eq "94104"
            expect(compliance_info.is_business).to be(false)
            expect(compliance_info.individual_tax_id.decrypt("1234")).to eq "6789"
          end
        end

        describe "user wishes to edit a frozen field (e.g. dob that may be edited if nil)" do
          let(:params) do
            {
              first_name: "barnabas",
              last_name: "barnabastein",
              street_address: "123 barnabas st",
              city: "barnabasville",
              state: "NY",
              zip_code: "94104",
              dba: "barnie",
              is_business: "off",
              ssn_last_four: "6789"
            }
          end

          before do
            params.merge!(dob_month: "02", dob_day: "01", dob_year: "1980")
            put :update, xhr: true, params: { user: params }
          end

          it "returns success" do
            expect(response.parsed_body["success"]).to be(true)
          end

          it "the users current compliance info should be changed" do
            compliance_info = user.fetch_or_build_user_compliance_info
            expect(compliance_info.first_name).to eq "barnabas"
            expect(compliance_info.last_name).to eq "barnabastein"
            expect(compliance_info.street_address).to eq "123 barnabas st"
            expect(compliance_info.city).to eq "barnabasville"
            expect(compliance_info.state).to eq "NY"
            expect(compliance_info.zip_code).to eq "94104"
            expect(compliance_info.is_business).to be(false)
            expect(compliance_info.individual_tax_id.decrypt("1234")).to eq "6789"
            expect(compliance_info.birthday).to eq(Date.new(1980, 2, 1))
          end
        end

        describe "user wishes to edit a non-frozen feild (e.g. address)" do
          before do
            params.merge!(street_address: "124 Barnabas St")
            put :update, xhr: true, params: { user: params }
          end

          it "returns success" do
            expect(response.parsed_body["success"]).to be(true)
          end

          it "the users current compliance info should contain the new address" do
            compliance_info = user.fetch_or_build_user_compliance_info
            expect(compliance_info.first_name).to eq "barnabas"
            expect(compliance_info.last_name).to eq "barnabastein"
            expect(compliance_info.street_address).to eq "124 Barnabas St"
            expect(compliance_info.city).to eq "barnabasville"
            expect(compliance_info.state).to eq "NY"
            expect(compliance_info.zip_code).to eq "94104"
            expect(compliance_info.is_business).to be(false)
            expect(compliance_info.individual_tax_id.decrypt("1234")).to eq "6789"
          end
        end

        it "allows the user to change the account type from individual to business" do
          # Save the account type as "individual"
          put :update, xhr: true, params: { user: params }

          # Then try to switch to the "business" account type
          params.merge!(
            is_business: "on",
            business_street_address: "123 main street",
            business_city: "sf",
            business_state: "CA",
            business_zip_code: "94107",
            business_type: UserComplianceInfo::BusinessTypes::LLC,
            business_tax_id: "123-123-123"
          )
          put :update, xhr: true, params: { user: params }

          expect(response.parsed_body["success"]).to be(true)

          compliance_info = user.alive_user_compliance_info
          expect(compliance_info.first_name).to eq "barnabas"
          expect(compliance_info.last_name).to eq "barnabastein"
          expect(compliance_info.street_address).to eq "123 barnabas st"
          expect(compliance_info.city).to eq "barnabasville"
          expect(compliance_info.state).to eq "NY"
          expect(compliance_info.zip_code).to eq "94104"
          expect(compliance_info.individual_tax_id.decrypt("1234")).to eq "6789"

          expect(compliance_info.is_business).to be(true)
          expect(compliance_info.business_street_address).to eq "123 main street"
          expect(compliance_info.business_city).to eq "sf"
          expect(compliance_info.business_state).to eq "CA"
          expect(compliance_info.business_zip_code).to eq "94107"
          expect(compliance_info.business_type).to eq "llc"
          expect(compliance_info.business_tax_id.decrypt("1234")).to eq "123-123-123"
        end
      end

      describe "user is verified, and their compliance info was old and is_business=nil when we created their merchant account" do
        before do
          params.merge!(
            is_business: nil
          )
          put :update, xhr: true, params: { user: params }
          compliance_info = user.fetch_or_build_user_compliance_info
          expect(compliance_info.is_business).to be(nil)
          user.merchant_accounts << create(:merchant_account, charge_processor_verified_at: Time.current)
        end

        describe "user submits their compliance info, and the new form submits is_business=off" do
          before do
            params.merge!(
              is_business: "off"
            )
            put :update, xhr: true, params: { user: params }
          end

          it "returns success" do
            expect(response.parsed_body["success"]).to be(true)
          end

          it "the users current compliance info should contain the same details" do
            compliance_info = user.fetch_or_build_user_compliance_info
            expect(compliance_info.first_name).to eq "barnabas"
            expect(compliance_info.last_name).to eq "barnabastein"
            expect(compliance_info.street_address).to eq "123 barnabas st"
            expect(compliance_info.city).to eq "barnabasville"
            expect(compliance_info.state).to eq "NY"
            expect(compliance_info.zip_code).to eq "94104"
            expect(compliance_info.individual_tax_id.decrypt("1234")).to eq "6789"
          end

          it "the users current compliance info should contain is_business=false" do
            compliance_info = user.fetch_or_build_user_compliance_info
            expect(compliance_info.is_business).to be(false)
          end
        end
      end
    end

    describe "business" do
      let(:business_params) do
        params.merge(
          is_business: "on",
          business_street_address: "123 main street",
          business_city: "sf",
          business_state: "CA",
          business_zip_code: "94107",
          business_type: UserComplianceInfo::BusinessTypes::LLC,
          business_tax_id: "123-123-123"
        )
      end

      it "updates the compliance information and return the proper response" do
        put :update, xhr: true, params: { user: business_params }
        compliance_info = user.fetch_or_build_user_compliance_info
        expect(compliance_info.first_name).to eq "barnabas"
        expect(compliance_info.last_name).to eq "barnabastein"
        expect(compliance_info.street_address).to eq "123 barnabas st"
        expect(compliance_info.city).to eq "barnabasville"
        expect(compliance_info.state).to eq "NY"
        expect(compliance_info.zip_code).to eq "94104"
        expect(compliance_info.individual_tax_id.decrypt("1234")).to eq "6789"

        expect(compliance_info.is_business).to be(true)
        expect(compliance_info.business_street_address).to eq "123 main street"
        expect(compliance_info.business_city).to eq "sf"
        expect(compliance_info.business_state).to eq "CA"
        expect(compliance_info.business_zip_code).to eq "94107"
        expect(compliance_info.business_type).to eq "llc"
        expect(compliance_info.business_tax_id.decrypt("1234")).to eq "123-123-123"

        expect(response.parsed_body["success"]).to be(true)
      end

      it "clears the requests that are present" do
        put :update, xhr: true, params: { user: business_params }
        request_1.reload
        request_2.reload
        request_3.reload
        request_4.reload
        expect(request_1.state).to eq("provided")
        expect(request_2.state).to eq("provided")
        expect(request_3.state).to eq("provided")
        expect(request_4.state).to eq("provided")
      end

      it "allows the user to change the account type from business to individual after verification" do
        # Save the account type as "business" and mark verified
        put :update, xhr: true, params: { user: business_params }
        user.merchant_accounts << create(:merchant_account, charge_processor_verified_at: Time.current)

        # Then try to switch to the "individual" account type
        business_params.merge!(is_business: "off")
        put :update, xhr: true, params: { user: business_params }

        expect(response.parsed_body["success"]).to be(true)

        compliance_info = user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq "barnabas"
        expect(compliance_info.last_name).to eq "barnabastein"
        expect(compliance_info.street_address).to eq "123 barnabas st"
        expect(compliance_info.city).to eq "barnabasville"
        expect(compliance_info.state).to eq "NY"
        expect(compliance_info.zip_code).to eq "94104"
        expect(compliance_info.is_business).to be(false)
        expect(compliance_info.individual_tax_id.decrypt("1234")).to eq "6789"

        expect(compliance_info.business_street_address).to eq "123 main street"
        expect(compliance_info.business_city).to eq "sf"
        expect(compliance_info.business_state).to eq "CA"
        expect(compliance_info.business_zip_code).to eq "94107"
        expect(compliance_info.business_type).to eq "llc"
        expect(compliance_info.business_tax_id.decrypt("1234")).to eq "123-123-123"
      end
    end

    describe "ach account" do
      let(:user) { create(:user) }
      before do
        sign_in user
      end

      describe "success" do
        let(:params) do
          {
            bank_account: {
              type: AchAccount.name,
              account_number: "000123456789",
              account_number_confirmation: "000123456789",
              routing_number: "110000000",
              account_holder_full_name: "gumbot"
            }
          }
        end

        let(:request) do
          create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::BANK_ACCOUNT)
        end

        before do
          request
        end

        it "creates the ach account" do
          put(:update, xhr: true, params:)

          bank_account = AchAccount.last
          expect(bank_account.account_number.decrypt("1234")).to eq "000123456789"
          expect(bank_account.account_number_last_four).to eq "6789"
          expect(bank_account.routing_number).to eq "110000000"
          expect(bank_account.account_holder_full_name).to eq "gumbot"
          expect(bank_account.account_type).to eq "checking"
        end

        it "clears the request for the bank account" do
          put(:update, xhr: true, params:)

          request.reload
          expect(request.state).to eq("provided")
        end

        context "with invalid bank code" do
          before do
            params[:bank_account][:type] = "SingaporeanBankAccount"
            params[:bank_account][:bank_code] = "BKCH"
          end

          it "returns error" do
            put(:update, xhr: true, params:)

            expect(response.parsed_body["success"]).to be(false)
            expect(response.parsed_body["error_message"]).to eq("The bank code is invalid. and The branch code is invalid.")
          end
        end
      end

      describe "success with dashes/hyphens and leading/trailing spaces" do
        let(:params) do
          {
            bank_account: {
              type: AchAccount.name,
              account_number: "  000-1234-56789 ",
              account_number_confirmation: " 000-1234-56789  ",
              routing_number: "110000000",
              account_holder_full_name: "gumbot"
            }
          }
        end

        let(:request) do
          create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::BANK_ACCOUNT)
        end

        before do
          request
        end

        it "creates the ach account" do
          put(:update, xhr: true, params:)
          bank_account = AchAccount.last
          expect(bank_account.account_number.decrypt("1234")).to eq "000123456789"
          expect(bank_account.account_number_last_four).to eq "6789"
          expect(bank_account.routing_number).to eq "110000000"
          expect(bank_account.account_holder_full_name).to eq "gumbot"
          expect(bank_account.account_type).to eq "checking"
        end

        it "clears the request for the bank account" do
          put(:update, xhr: true, params:)
          request.reload
          expect(request.state).to eq("provided")
        end
      end

      describe "account number and repeated account number don't match" do
        let(:params) do
          {
            bank_account: {
              type: AchAccount.name,
              account_number: "123123123",
              account_number_confirmation: "222222222",
              routing_number: "110000000",
              account_holder_full_name: "gumbot"
            }
          }
        end

        let(:request) do
          create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::BANK_ACCOUNT)
        end

        before do
          request
        end

        it "fails if the account numbers don't match" do
          put(:update, xhr: true, params:)
          expect(response.parsed_body["success"]).to be(false)
        end

        it "does not clear the request for the bank account" do
          put(:update, xhr: true, params:)
          request.reload
          expect(request.state).to eq("requested")
        end
      end

      describe "canadian bank account" do
        let(:user) { create(:user) }

        before do
          user.alive_user_compliance_info.update_columns(country: "Canada")
          sign_in user
        end

        describe "success" do
          let(:params) do
            {
              bank_account: {
                type: CanadianBankAccount.name,
                account_number: "000123456789",
                account_number_confirmation: "000123456789",
                transit_number: "11000",
                institution_number: "000",
                account_holder_full_name: "gumbot"
              }
            }
          end

          let(:request) do
            create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::BANK_ACCOUNT)
          end

          before do
            request
          end

          it "creates the ach account" do
            put(:update, xhr: true, params:)
            bank_account = CanadianBankAccount.last
            expect(bank_account.account_number.decrypt("1234")).to eq "000123456789"
            expect(bank_account.account_number_last_four).to eq "6789"
            expect(bank_account.routing_number).to eq "11000-000"
            expect(bank_account.account_holder_full_name).to eq "gumbot"
          end

          it "clears the request for the bank account" do
            put(:update, xhr: true, params:)
            request.reload
            expect(request.state).to eq("provided")
          end
        end

        describe "account number and repeated account number don't match" do
          let(:params) do
            {
              bank_account: {
                type: CanadianBankAccount.name,
                account_number: "123123123",
                account_number_confirmation: "222222222",
                transit_number: "22222",
                institution_number: "111",
                account_holder_full_name: "gumbot"
              }
            }
          end

          let(:request) do
            create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::BANK_ACCOUNT)
          end

          before do
            request
          end

          it "fails if the account numbers don't match" do
            put(:update, xhr: true, params:)
            expect(response.parsed_body["success"]).to be(false)
          end

          it "does not clear the request for the bank account" do
            put(:update, xhr: true, params:)
            request.reload
            expect(request.state).to eq("requested")
          end
        end
      end

      describe "australian bank account" do
        let(:user) { create(:user) }

        before do
          user.alive_user_compliance_info.update_columns(country: "Australia")
          sign_in user
        end

        describe "success" do
          let(:params) do
            {
              bank_account: {
                type: AustralianBankAccount.name,
                account_number: "000123456",
                account_number_confirmation: "000123456",
                bsb_number: "110000",
                account_holder_full_name: "gumbot"
              }
            }
          end

          let(:request) do
            create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::BANK_ACCOUNT)
          end

          before do
            request
          end

          it "creates the ach account" do
            put(:update, xhr: true, params:)
            bank_account = AustralianBankAccount.last
            expect(bank_account.account_number.decrypt("1234")).to eq "000123456"
            expect(bank_account.account_number_last_four).to eq "3456"
            expect(bank_account.routing_number).to eq "110000"
            expect(bank_account.account_holder_full_name).to eq "gumbot"
            expect(user.reload.stripe_account).to be_present
          end

          it "clears the request for the bank account" do
            put(:update, xhr: true, params:)
            request.reload
            expect(request.state).to eq("provided")
          end
        end

        describe "account number and repeated account number don't match" do
          let(:params) do
            {
              bank_account: {
                type: AustralianBankAccount.name,
                account_number: "123123123",
                account_number_confirmation: "222222222",
                transit_number: "223222",
                account_holder_full_name: "gumbot"
              }
            }
          end

          let(:request) do
            create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::BANK_ACCOUNT)
          end

          before do
            request
          end

          it "fails if the account numbers don't match" do
            put(:update, xhr: true, params:)
            expect(response.parsed_body["success"]).to be(false)
            expect(response.parsed_body["error_message"]).to eq("The account numbers do not match.")
          end

          it "does not clear the request for the bank account" do
            put(:update, xhr: true, params:)
            request.reload
            expect(request.state).to eq("requested")
          end
        end
      end

      describe "uk bank account" do
        let(:user) { create(:user) }

        before do
          user.alive_user_compliance_info.update_columns(country: "United Kingdom")
          sign_in user
        end

        describe "success" do
          let(:params) do
            {
              bank_account: {
                type: UkBankAccount.name,
                account_number: "00012345",
                account_number_confirmation: "00012345",
                sort_code: "23-14-70",
                account_holder_full_name: "gumbot"
              }
            }
          end

          let(:request) do
            create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::BANK_ACCOUNT)
          end

          before do
            request
          end

          it "creates the ach account" do
            put(:update, xhr: true, params:)
            bank_account = UkBankAccount.last
            expect(bank_account.account_number.decrypt("1234")).to eq "00012345"
            expect(bank_account.account_number_last_four).to eq "2345"
            expect(bank_account.routing_number).to eq "23-14-70"
            expect(bank_account.account_holder_full_name).to eq "gumbot"
          end

          it "clears the request for the bank account" do
            put(:update, xhr: true, params:)
            request.reload
            expect(request.state).to eq("provided")
          end
        end

        describe "account number and repeated account number don't match" do
          let(:params) do
            {
              bank_account: {
                type: UkBankAccount.name,
                account_number: "123123123",
                account_number_confirmation: "222222222",
                transit_number: "22-32-22",
                account_holder_full_name: "gumbot"
              }
            }
          end

          let(:request) do
            create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::BANK_ACCOUNT)
          end

          before do
            request
          end

          it "fails if the account numbers don't match" do
            put(:update, xhr: true, params:)
            expect(response.parsed_body["success"]).to be(false)
          end

          it "does not clear the request for the bank account" do
            put(:update, xhr: true, params:)
            request.reload
            expect(request.state).to eq("requested")
          end
        end
      end
    end

    context "when setting the PayPal payout address" do
      before do
        user.update!(user_risk_state: "compliant", payment_address: "sam@example.com")
      end

      it "fails if payout address contains non-ASCII characters" do
        put :update, xhr: true, params: { payment_address: "sebastian.ripenås@example.com" }

        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error_message"]).to eq("Email address cannot contain non-ASCII characters")
      end

      it "fails if bank payouts are supported in seller's country" do
        put :update, xhr: true, params: { payment_address: "sebastian@example.com" }

        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error_message"]).to eq("PayPal payouts are not supported in your country.")
      end

      it "succeeds if bank payouts are not supported in seller's country" do
        user.alive_user_compliance_info.dup_and_save { |nuci| nuci.country = "Brazil" }

        put :update, xhr: true, params: { payment_address: "sebastian@example.com" }

        expect(response.parsed_body["success"]).to be(true)
        expect(user.reload.payment_address).to eq("sebastian@example.com")
      end

      it "resumes payouts if account is not flagged or suspended" do
        user.update!(payment_address: "")
        stripe_account = create(:merchant_account_stripe, user: user)
        create(:user_compliance_info_request, user: user, field_needed: UserComplianceInfoFields::Individual::TAX_ID)
        user.update!(payouts_paused_internally: true)
        user.alive_user_compliance_info.dup_and_save { |nuci| nuci.country = "Brazil" }

        put :update, xhr: true, params: { payment_address: "sebastian@example.com" }

        expect(user.reload.payment_address).to eq("sebastian@example.com")
        expect(stripe_account.reload.alive?).to be false
        expect(user.user_compliance_info_requests.requested.count).to eq(0)
        expect(user.payouts_paused_internally?).to be false
      end

      it "does not resume payouts if account is flagged or suspended" do
        user.update!(payment_address: "", user_risk_state: "flagged_for_fraud")
        stripe_account = create(:merchant_account_stripe, user: user)
        create(:user_compliance_info_request, user: user, field_needed: UserComplianceInfoFields::Individual::TAX_ID)
        user.update!(payouts_paused_internally: true)
        user.alive_user_compliance_info.dup_and_save { |nuci| nuci.country = "Brazil" }

        put :update, xhr: true, params: { payment_address: "sebastian@example.com" }

        expect(user.reload.payment_address).to eq("sebastian@example.com")
        expect(stripe_account.reload.alive?).to be false
        expect(user.user_compliance_info_requests.requested.count).to eq(0)
        expect(user.payouts_paused_internally?).to be true
      end
    end

    context "when setting a debit card as the payout method", :vcr do
      before do
        user.update!(user_risk_state: "compliant", payment_address: nil)
        create(:card_bank_account, user:)

        @card_params = lambda do |number: "4000056655665556", exp_month: 12, exp_year: 2023|
          card_token = Stripe::Token.create(
            card: {
              number:,
              exp_month:,
              exp_year:,
              cvc: "123"
            }
          )

          { card: { stripe_token: card_token.id } }
        end
      end

      it "succeeds when the previous payout method was a bank account" do
        user.active_bank_account.destroy!
        create(:uk_bank_account, user:)

        put :update, xhr: true, params: @card_params.call

        expect(response.parsed_body["success"]).to be(true)

        user.reload
        active_bank_account = user.active_bank_account
        expect(active_bank_account).to be_an_instance_of(CardBankAccount)

        credit_card = active_bank_account.credit_card
        expect(credit_card.visual).to eq("**** **** **** 5556")
        expect(credit_card.expiry_month).to eq(12)
        expect(credit_card.expiry_year).to eq(2023)
      end
    end

    context "when updating country" do
      it "calls UpdateUserCountry service" do
        expect(UpdateUserCountry).to receive(:new).with(new_country_code: "GB", user:).and_call_original

        put :update, xhr: true, params: { user: { updated_country_code: "GB" } }

        expect(flash[:notice]).to eq("Your country has been updated!")
      end

      it "notifies Bugsnag if there is an error" do
        expect(Bugsnag).to receive(:notify).exactly(:once)
        allow_any_instance_of(User).to receive(:update!).and_raise(StandardError)

        put :update, xhr: true, params: { user: { updated_country_code: "GB" } }

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["error_message"]).to eq("Country update failed")
      end
    end
  end

  describe "POST set_country" do
    let(:user) { create(:user) }
    let(:params) { { country: "US", zip_code: "94104" } }

    before do
      sign_in user
    end

    it "updates the country and returns the proper response" do
      post :set_country, params:, as: :json

      expect(response).to be_successful

      user.reload
      compliance_info = user.fetch_or_build_user_compliance_info
      expect(compliance_info.country).to eq "United States"
    end

    describe "user compliance info" do
      it "creates a new user compliance info" do
        expect do
          post :set_country, params:, as: :json
        end.to change { UserComplianceInfo.count }.by(2)

        expect(response).to be_successful
      end

      it "creates compliance info without a country" do
        expect do
          post :set_country, params: params.except(:country), as: :json
        end.to change { UserComplianceInfo.count }.by(2)
        expect(response).to be_successful
      end
    end

    describe "user selects specific country" do
      describe "US" do
        it "sets the default currency to USD" do
          post :set_country, params:, as: :json

          expect(response).to be_successful
          user.reload
          expect(user.currency_type).to eq(Currency::USD)
        end
      end

      describe "CA" do
        it "sets the default currency to CAD" do
          post :set_country, params: params.merge(country: "CA"), as: :json

          expect(response).to be_successful
          user.reload
          expect(user.currency_type).to eq(Currency::CAD)
        end
      end
    end
  end

  describe "POST opt_in_to_au_backtax_collection" do
    let(:creator) { create(:user_with_compliance_info) }
    let(:params) { { signature: "Chuck Bartowski" } }

    before do
      sign_in creator
    end

    it "creates the backtax agreement and returns the proper response" do
      post :opt_in_to_au_backtax_collection, params:, as: :json

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)

      creator.reload
      expect(creator.backtax_agreements.count).to eq(1)
    end

    it "returns an error if the signature is not the same length as the name in the creator's settings" do
      post :opt_in_to_au_backtax_collection, params: params.merge(signature: "Chuck"), as: :json

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["error"]).to eq("Please enter your exact name.")
    end
  end

  describe "GET paypal_connect" do
    def paypal_params(paypal_merchant_reference:)
      {
        merchantId: "6",
        merchantIdInPayPal: paypal_merchant_reference,
        permissionsGranted: "true",
        accountStatus: "BUSINESS_ACCOUNT",
        consentStatus: "true",
        productIntentID: "addipmt",
        isEmailConfirmed: "true"
      }
    end

    before do
      seller.mark_compliant!(author_name: "Iffy")
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(100_00)
      create(:payment_completed, user: seller)
    end

    context "when the user has merchant migration enabled" do
      before do
        seller.check_merchant_account_is_linked = true
        seller.save
      end

      context "when PayPal account connection is successful" do
        it "creates a new MerchantAccount record and redirects the user on success" do
          current_time = Time.current.change(usec: 0)
          travel_to(current_time) do
            expect do
              get :paypal_connect, params: paypal_params(paypal_merchant_reference: "A8RLJ7R5E389A")
            end.to change { MerchantAccount.count }.by(1)
          end

          merchant_account = MerchantAccount.last
          expect(merchant_account.charge_processor_id).to eq(PaypalChargeProcessor.charge_processor_id)
          expect(merchant_account.charge_processor_merchant_id).to eq("A8RLJ7R5E389A")
          expect(merchant_account.charge_processor_alive_at).to eq(current_time)
          expect(merchant_account.meta["merchantId"]).to eq("6")
          expect(merchant_account.meta["permissionsGranted"]).to eq("true")
          expect(merchant_account.meta["accountStatus"]).to eq("BUSINESS_ACCOUNT")
          expect(merchant_account.meta["consentStatus"]).to eq("true")
          expect(merchant_account.meta["productIntentID"]).to eq("addipmt")
          expect(merchant_account.meta["isEmailConfirmed"]).to eq("true")
          expect(seller.reload.check_merchant_account_is_linked).to be(true)

          expect(response).to redirect_to(settings_payments_path)
        end
      end

      context "when PayPal account connection is not successful" do
        it "redirects user to payments settings path" do
          get :paypal_connect, params: paypal_params(paypal_merchant_reference: nil)
          expect(response).to redirect_to(settings_payments_path)
        end

        it "allows same PayPal account to be connected even when it is already connected to the another Gumroad Account" do
          merchant_account = create(:merchant_account_paypal, charge_processor_merchant_id: "A8RLJ7R5E389A")
          expect do
            get :paypal_connect, params: paypal_params(paypal_merchant_reference: merchant_account.charge_processor_merchant_id)
          end.to change { MerchantAccount.count }.by(1)
        end

        context "when there is some error connecting PayPal account" do
          it "flashes PayPal account connection error" do
            get :paypal_connect, params: paypal_params(paypal_merchant_reference: nil)
            expect(response).to redirect_to(settings_payments_path)
            expect(flash[:notice]).to eq("There was an error connecting your PayPal account with Gumroad.")
          end
        end
      end
    end

    context "when the user has merchant migration enabled by way of the feature flag" do
      before do
        seller.check_merchant_account_is_linked = false
        seller.save

        Feature.activate_user(:merchant_migration, seller)
      end

      after do
        Feature.deactivate_user(:merchant_migration, seller)
      end

      context "when the PayPal account connection is successful" do
        it "does not set the `check_merchant_account_is_linked` property to `true` for the user on success" do
          expect do
            get :paypal_connect, params: paypal_params(paypal_merchant_reference: "A8RLJ7R5E389A")
          end.to change { MerchantAccount.count }.by(1)

          expect(seller.reload.check_merchant_account_is_linked).to be(false)
          expect(response).to redirect_to(settings_payments_path)
        end
      end
    end

    context "when PayPal account connection is successful" do
      it "creates a new MerchantAccount record and redirects the user on success" do
        current_time = Time.current.change(usec: 0)
        travel_to(current_time) do
          expect do
            get :paypal_connect, params: paypal_params(paypal_merchant_reference: "A8RLJ7R5E389A")
          end.to change { MerchantAccount.count }.by(1)
        end

        merchant_account = MerchantAccount.last
        expect(merchant_account.charge_processor_id).to eq(PaypalChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to eq("A8RLJ7R5E389A")
        expect(merchant_account.charge_processor_alive_at).to eq(current_time)
        expect(merchant_account.meta["merchantId"]).to eq("6")
        expect(merchant_account.meta["permissionsGranted"]).to eq("true")
        expect(merchant_account.meta["accountStatus"]).to eq("BUSINESS_ACCOUNT")
        expect(merchant_account.meta["consentStatus"]).to eq("true")
        expect(merchant_account.meta["productIntentID"]).to eq("addipmt")
        expect(merchant_account.meta["isEmailConfirmed"]).to eq("true")
        expect(seller.reload.check_merchant_account_is_linked).to be(false)

        expect(response).to redirect_to(settings_payments_path)
      end
    end

    context "when PayPal account connection is not successful" do
      it "redirects user to payments settings path" do
        get :paypal_connect, params: paypal_params(paypal_merchant_reference: nil)
        expect(response).to redirect_to(settings_payments_path)
      end

      it "allows same PayPal account to be connected even when it is already connected to the another Gumroad Account" do
        merchant_account = create(:merchant_account_paypal, charge_processor_merchant_id: "A8RLJ7R5E389A")
        expect do
          get :paypal_connect, params: paypal_params(paypal_merchant_reference: merchant_account.charge_processor_merchant_id)
        end.to change { MerchantAccount.count }.by(1)
      end

      context "when there is some error connecting PayPal account" do
        it "flashes PayPal account connection error" do
          get :paypal_connect, params: paypal_params(paypal_merchant_reference: nil)
          expect(flash[:notice]).to eq("There was an error connecting your PayPal account with Gumroad.")
        end
      end

      context "when the user's country is not supported by paypal commerce platform" do
        before do
          seller.alive_user_compliance_info.update_columns(country: "India")
        end

        it "still connects the paypal account if paypal account is from a supported country" do
          get :paypal_connect, params: paypal_params(paypal_merchant_reference: "A8RLJ7R5E389A")
          expect(response).to redirect_to(settings_payments_path)
          expect(flash[:notice]).to eq("You have successfully connected your PayPal account with Gumroad.")
          expect(seller.merchant_accounts.count).to eq(1)
        end
      end

      context "when PayPal returns C2 instead of CN as country code for Chinese accounts" do
        before do
          seller.alive_user_compliance_info.update_columns(country: "China")
        end

        it "still connects the paypal account" do
          get :paypal_connect, params: paypal_params(paypal_merchant_reference: "MUWSRAF6QLQJG")

          expect(response).to redirect_to(settings_payments_path)
          expect(flash[:notice]).to eq("You have successfully connected your PayPal account with Gumroad.")
          expect(seller.merchant_accounts.count).to eq(1)
          expect(seller.merchant_accounts.paypal.last.country).to eq("CN")
        end
      end

      context "when the user's paypal account country is not supported by paypal commerce platform" do
        it "redirects to payments settings page with proper error message" do
          expect(seller.alive_user_compliance_info.country).to eq("United States")

          get :paypal_connect, params: paypal_params(paypal_merchant_reference: "U6E6N859GJJYQ")

          expect(response).to redirect_to(settings_payments_path)
          expect(flash[:notice]).to eq("Your PayPal account could not be connected because this PayPal integration is not supported in your country.")
          expect(seller.merchant_accounts.alive.count).to eq(0)
        end
      end
    end
  end

  describe "POST remove_credit_card" do
    it "returns failure if credit card is required by the user, else removes the credit card and returns success" do
      user_with_credit_card = create(:user, credit_card: create(:credit_card))
      sign_in user_with_credit_card
      expect(user_with_credit_card.reload.credit_card).to_not be(nil)

      allow_any_instance_of(User).to receive(:requires_credit_card?).and_return(true)
      post :remove_credit_card
      expect(response).to have_http_status :bad_request
      expect(user_with_credit_card.reload.credit_card).not_to be(nil)

      allow_any_instance_of(User).to receive(:requires_credit_card?).and_return(false)
      post :remove_credit_card
      expect(response).to be_successful
      expect(user_with_credit_card.reload.credit_card).to be(nil)
    end
  end

  describe "GET remediation" do
    let!(:user) { create(:user) }
    let!(:user_compliance_info) { create(:user_compliance_info, user:) }
    let!(:bank_account) { create(:ach_account_stripe_succeed, user:) }
    let!(:tos_agreement) { create(:tos_agreement, user:) }

    before do
      sign_in user
    end

    it "does noting and redirects to payments settings page if there's no associated stripe account" do
      get :remediation

      expect(response).to redirect_to settings_payments_url
    end

    it "does noting and redirects to payments settings page if there's no pending stripe information request" do
      StripeMerchantAccountManager.create_account(user, passphrase: "1234")

      get :remediation

      expect(response).to redirect_to settings_payments_url
    end

    it "generates a remediation link for the associated Stripe account and redirects to it" do
      stripe_connect_account_id = StripeMerchantAccountManager.create_account(user, passphrase: "1234").charge_processor_merchant_id

      create(:user_compliance_info_request,
             user:,
             field_needed: "interv_cmVxbXRfMVEyOTViUzhuV09PRjdyT0ZPamtGelgxv1000c65GRfs.supportability.intellectual_property_usage.form")

      expect(Stripe::AccountLink).to receive(:create).with({
                                                             account: stripe_connect_account_id,
                                                             refresh_url: remediation_settings_payments_url,
                                                             return_url: verify_stripe_remediation_settings_payments_url,
                                                             type: "account_onboarding",
                                                           }).and_call_original

      get :remediation

      expect(response.location).to match(Regexp.new("https://connect.stripe.com/setup/c/#{stripe_connect_account_id}/"))
    end
  end

  describe "GET verify_stripe_remediation" do
    let!(:user) { create(:user) }
    let!(:user_compliance_info) { create(:user_compliance_info, user:) }
    let!(:bank_account) { create(:ach_account_stripe_succeed, user:) }
    let!(:tos_agreement) { create(:tos_agreement, user:) }
    let!(:stripe_connect_account_id) { StripeMerchantAccountManager.create_account(user, passphrase: "1234").charge_processor_merchant_id }

    before do
      sign_in user
    end

    it "redirects to the payments settings page" do
      get :verify_stripe_remediation

      expect(response).to redirect_to settings_payments_url
      expect(flash[:notice]).to eq("Thanks! You're all set.")
    end
  end
end
