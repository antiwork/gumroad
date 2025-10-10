# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe BalanceController, type: :controller, inertia: true do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }
  let(:payout) { create(:payment, user: seller) }

  before do
    create_list(:payment_completed, 5, user: seller)
  end

  describe "GET index" do
    include_context "with user signed in as admin for seller"

    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { :balance }
      let(:policy_method) { :index? }
    end

    it "assigns the correct instance variables and renders template" do
      expect(UserBalanceStatsService).to receive(:new).with(user: seller).and_call_original

      get :index
      expect(response).to be_successful
      expect(inertia.component).to eq("Payouts/Index")
      expect(inertia.props[:payout_presenter][:next_payout_period_data]).to eq({
                                                                                 should_be_shown_currencies_always: false,
                                                                                 minimum_payout_amount_cents: 1000,
                                                                                 is_user_payable: false,
                                                                                 status: "not_payable",
                                                                                 payout_note: nil,
                                                                                 has_stripe_connect: false
                                                                               })
    end
  end

  describe "GET payments_paged" do
    let(:payments_per_page) { 2 }

    before do
      stub_const("BalanceController::PAST_PAYMENTS_PER_PAGE", payments_per_page)
    end

    include_context "with user signed in as admin for seller"

    it_behaves_like "authorize called for action", :get, :payments_paged do
      let(:record) { :balance }
      let(:policy_method) { :index? }
    end

    it "renders JSON response" do
      get :payments_paged, xhr: true
      expect(response).to be_successful

      json_response = response.parsed_body
      expect(json_response["payouts"].count).to eq(payments_per_page)
      expect(json_response["payouts"].first.keys).to include("payout_currency", "payout_cents", "payout_displayed_amount")
      expect(json_response["pagination"]).to be_present
    end
  end
end
