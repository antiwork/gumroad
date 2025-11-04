# frozen_string_literal: true

require "spec_helper"

describe Api::Internal::Helper::PayoutsController do
  let(:user) { create(:compliant_user) }
  let(:helper_token) { GlobalConfig.get("HELPER_TOOLS_TOKEN") }

  before do
    request.headers["Authorization"] = "Bearer #{helper_token}"
    stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)
  end

  it "inherits from Api::Internal::Helper::BaseController" do
    expect(described_class.superclass).to eq(Api::Internal::Helper::BaseController)
  end

  describe "GET index" do
    context "when user is not found" do
      it "returns 404" do
        get :index, params: { email: "nonexistent@example.com" }
        expect(response.status).to eq(404)
        parsed_response = JSON.parse(response.body)
        expect(parsed_response["success"]).to be(false)
        expect(parsed_response["message"]).to eq("User not found")
      end
    end

    context "when user exists" do
      let!(:payment1) { create(:payment_completed, user:, created_at: 1.day.ago, bank_account: create(:ach_account_stripe_succeed, user:)) }
      let!(:payment2) { create(:payment_failed, user:, created_at: 2.days.ago) }
      let!(:payment3) { create(:payment, user:, created_at: 3.days.ago) }
      let!(:payment4) { create(:payment_completed, user:, created_at: 4.days.ago) }
      let!(:payment5) { create(:payment_completed, user:, created_at: 5.days.ago, processor: PayoutProcessorType::PAYPAL, payment_address: "payme@example.com") }
      let!(:payment6) { create(:payment_completed, user:, created_at: 6.days.ago) }

      before do
        allow_any_instance_of(User).to receive(:next_payout_date).and_return(Date.tomorrow)
        allow_any_instance_of(User).to receive(:formatted_balance_for_next_payout_date).and_return("$100.00")
      end

      it "returns last 5 payouts and next payout information" do
        payout_note = "Payout paused due to verification"
        user.add_payout_note(content: payout_note)

        get :index, params: { email: user.email }

        expect(response.status).to eq(200)
        parsed_response = JSON.parse(response.body)
        expect(parsed_response["success"]).to be(true)

        payouts = parsed_response["last_payouts"]
        expect(payouts.length).to eq(5)

        expect(payouts.first["external_id"]).to eq(payment1.external_id)
        expect(payouts.first["amount_cents"]).to eq(payment1.amount_cents)
        expect(payouts.first["currency"]).to eq(payment1.currency)
        expect(payouts.first["state"]).to eq(payment1.state)
        expect(payouts.first["processor"]).to eq(payment1.processor)
        expect(payouts.first["bank_account_visual"]).to eq("******6789")
        expect(payouts.first["paypal_email"]).to be nil

        expect(payouts.last["external_id"]).to eq(payment5.external_id)
        expect(payouts.last["amount_cents"]).to eq(payment5.amount_cents)
        expect(payouts.last["currency"]).to eq(payment5.currency)
        expect(payouts.last["state"]).to eq(payment5.state)
        expect(payouts.last["processor"]).to eq(payment5.processor)
        expect(payouts.last["bank_account_visual"]).to be nil
        expect(payouts.last["paypal_email"]).to eq "payme@example.com"

        expect(payouts.map { |p| p["external_id"] }).not_to include(payment6.external_id)

        expect(parsed_response["next_payout_date"]).to eq(Date.tomorrow.to_s)
        expect(parsed_response["balance_for_next_payout"]).to eq("$100.00")
        expect(parsed_response["payout_note"]).to eq(payout_note)
      end

      it "returns nil for payout_note when no note exists" do
        get :index, params: { email: user.email }

        parsed_response = JSON.parse(response.body)
        expect(parsed_response["payout_note"]).to be_nil
      end
    end

    context "when authorization header is missing" do
      it "returns unauthorized" do
        request.headers["Authorization"] = nil
        get :index, params: { email: user.email }
        expect(response.status).to eq(401)
      end
    end

    context "when helper token is invalid" do
      it "returns unauthorized" do
        request.headers["Authorization"] = "Bearer invalid_token"
        get :index, params: { email: user.email }
        expect(response.status).to eq(401)
      end
    end
  end

  describe "POST create" do
    let(:params) { { email: user.email } }

    context "when user is not found" do
      it "returns 404" do
        post :create, params: { email: "nonexistent@example.com" }
        expect(response.status).to eq(404)
        parsed_response = JSON.parse(response.body)
        expect(parsed_response["success"]).to be(false)
        expect(parsed_response["message"]).to eq("User not found")
      end
    end

    context "when user exists" do
      context "when last successful payout was less than a week ago" do
        before do
          create(:payment_completed, user:, created_at: 3.days.ago)
        end

        it "returns error message" do
          post :create, params: params
          expect(response.status).to eq(422)
          parsed_response = JSON.parse(response.body)
          expect(parsed_response["success"]).to be(false)
          expect(parsed_response["message"]).to eq("Cannot create payout. Last successful payout was less than a week ago.")
        end
      end

      context "when user is not compliant" do
        let(:user) { create(:user) }

        before do
          create(:payment_completed, user:, created_at: 8.days.ago)
          create(:balance, user:, date: 10.days.ago, amount_cents: 20_00)
          create(:ach_account_stripe_succeed, user:)
          create(:merchant_account_stripe, user:)
        end

        it "returns error message", :vcr do
          post :create, params: params
          expect(response.status).to eq(422)
          parsed_response = JSON.parse(response.body)
          expect(parsed_response["success"]).to be(false)
          expect(parsed_response["message"]).to include("User is not eligible for payout")
        end
      end

      context "when last successful payout was more than a week ago" do
        before do
          create(:payment_completed, user:, created_at: 8.days.ago)
          create(:balance, user:, date: 10.days.ago, amount_cents: 20_00)
        end

        context "when user is payable" do
          before do
            create(:ach_account_stripe_succeed, user:)
            create(:merchant_account_stripe, user:)
          end

          context "when payout creation succeeds", :vcr do
            it "creates a new payout and returns payout information" do
              post :create, params: params
              expect(response.status).to eq(200)
              parsed_response = JSON.parse(response.body)
              expect(parsed_response["success"]).to be(true)
              expect(parsed_response["message"]).to eq("Successfully created payout")

              payment = user.payments.last
              payout = parsed_response["payout"]
              expect(payout["external_id"]).to eq(payment.external_id)
              expect(payout["amount_cents"]).to eq(payment.amount_cents)
              expect(payout["currency"]).to eq(payment.currency)
              expect(payout["state"]).to eq(payment.state)
              expect(payout["processor"]).to eq(payment.processor)
              expect(payout["created_at"]).to be_present
              expect(payout["bank_account_visual"]).to eq "******6789"
              expect(payout["paypal_email"]).to be nil
            end
          end

          context "when payout creation fails", :vcr do
            before do
              allow(Payouts).to receive(:create_payment).and_return([nil, "Some error"])
            end

            it "returns error message" do
              post :create, params: params
              expect(response.status).to eq(422)
              parsed_response = JSON.parse(response.body)
              expect(parsed_response["success"]).to be(false)
              expect(parsed_response["message"]).to eq("Unable to create payout")
            end
          end
        end

        context "when user is not payable", :vcr do
          before do
            allow(Payouts).to receive(:is_user_payable).and_return(false)
          end

          it "returns error message" do
            post :create, params: params
            expect(response.status).to eq(422)
            parsed_response = JSON.parse(response.body)
            expect(parsed_response["success"]).to be(false)
            expect(parsed_response["message"]).to eq("User is not eligible for payout.")
          end
        end

        context "when user is payable via PayPal", :vcr do
          it "creates a new payout via PayPal and returns payout information" do
            user.update!(payment_address: "paypal-gr-integspecs@gumroad.com")
            create(:user_compliance_info, user:)

            post :create, params: params
            expect(response.status).to eq(200)
            parsed_response = JSON.parse(response.body)
            expect(parsed_response["success"]).to be(true)
            expect(parsed_response["message"]).to eq("Successfully created payout")

            payment = user.payments.last
            payout = parsed_response["payout"]
            expect(payout["external_id"]).to eq(payment.external_id)
            expect(payout["amount_cents"]).to eq(payment.amount_cents)
            expect(payout["currency"]).to eq(payment.currency)
            expect(payout["state"]).to eq(payment.state)
            expect(payout["processor"]).to eq(payment.processor)
            expect(payout["created_at"]).to be_present
            expect(payout["bank_account_visual"]).to be nil
            expect(payout["paypal_email"]).to eq("paypal-gr-integspecs@gumroad.com")
          end
        end

        context "when user does not have any payment method", :vcr do
          it "returns error message" do
            user.update!(payment_address: "")

            post :create, params: params
            expect(response.status).to eq(422)
            parsed_response = JSON.parse(response.body)
            expect(parsed_response["success"]).to be(false)
            expect(parsed_response["message"]).to eq("Cannot create payout. Payout method not set up.")
          end
        end
      end
    end

    context "when authorization header is missing" do
      it "returns unauthorized" do
        request.headers["Authorization"] = nil
        post :create, params: params
        expect(response.status).to eq(401)
      end
    end

    context "when helper token is invalid" do
      it "returns unauthorized" do
        request.headers["Authorization"] = "Bearer invalid_token"
        post :create, params: params
        expect(response.status).to eq(401)
      end
    end
  end
end
