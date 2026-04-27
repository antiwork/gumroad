# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::PayoutsController do
  let(:user) { create(:compliant_user) }

  before do
    stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)
  end

  describe "POST list" do
    include_examples "admin api authorization required", :post, :list

    it "returns the user's recent payouts and next payout information" do
      payment1 = create(:payment_completed, user:, created_at: 1.day.ago, bank_account: create(:ach_account_stripe_succeed, user:))
      create(:payment_failed, user:, created_at: 2.days.ago)
      create(:payment, user:, created_at: 3.days.ago)
      create(:payment_completed, user:, created_at: 4.days.ago)
      payment5 = create(:payment_completed, user:, created_at: 5.days.ago, processor: PayoutProcessorType::PAYPAL, payment_address: "payme@example.com")
      payment6 = create(:payment_completed, user:, created_at: 6.days.ago)
      payout_note = "Payout paused due to verification"
      user.add_payout_note(content: payout_note)

      allow_any_instance_of(User).to receive(:next_payout_date).and_return(Date.tomorrow)
      allow_any_instance_of(User).to receive(:formatted_balance_for_next_payout_date).and_return("$100.00")

      post :list, params: { email: user.email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["next_payout_date"]).to eq(Date.tomorrow.to_s)
      expect(response.parsed_body["balance_for_next_payout"]).to eq("$100.00")
      expect(response.parsed_body["payout_note"]).to eq(payout_note)

      payouts = response.parsed_body["last_payouts"]
      expect(payouts.length).to eq(5)
      expect(payouts.first).to include(
        "external_id" => payment1.external_id,
        "amount_cents" => payment1.amount_cents,
        "currency" => payment1.currency,
        "state" => payment1.state,
        "processor" => payment1.processor,
        "bank_account_visual" => "******6789",
        "paypal_email" => nil
      )
      expect(payouts.last).to include(
        "external_id" => payment5.external_id,
        "processor" => payment5.processor,
        "bank_account_visual" => nil,
        "paypal_email" => "payme@example.com"
      )
      expect(payouts.map { _1["external_id"] }).not_to include(payment6.external_id)
    end

    it "returns a bad request when email is missing" do
      post :list

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email is required" }.as_json)
    end

    it "returns not found when the user does not exist" do
      post :list, params: { email: "missing@example.com" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end
  end
end
