# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe BalanceController, type: :controller, inertia: true do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

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
      expect(inertia.props[:next_payout_period_data]).to eq({
                                                              should_be_shown_currencies_always: false,
                                                              minimum_payout_amount_cents: 1000,
                                                              is_user_payable: false,
                                                              status: "not_payable",
                                                              payout_note: nil,
                                                              has_stripe_connect: false
                                                            })
      expect(inertia.props[:past_payout_period_data]).to be_present
      expect(inertia.props[:pagination]).to be_present
    end

    context "with pagination" do
      let(:payments_per_page) { 2 }

      before do
        stub_const("PayoutsPresenter::PAST_PAYMENTS_PER_PAGE", payments_per_page)
      end

      it "returns correct payouts for subsequent pages" do
        get :index, params: { page: 2 }

        expect(response).to be_successful
        expect(inertia.props[:past_payout_period_data]).to be_an(Array)
        expect(inertia.props[:past_payout_period_data].length).to eq(payments_per_page)
      end
    end
  end
end
