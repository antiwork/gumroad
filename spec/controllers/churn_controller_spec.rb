# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe ChurnController, type: :controller, inertia: true do
  let(:seller) { create(:named_seller) }
  let(:churn_data) { { placeholder: "churn data" } }
  let(:service) { instance_double(CreatorAnalytics::Churn, generate_data: churn_data) }

  before do
    allow(CreatorAnalytics::Churn).to receive(:new).and_return(service)
    Feature.activate_user(:churn_analytics_enabled, seller)
  end

  describe "GET show" do
    include_context "with user signed in as admin for seller"

    it_behaves_like "authorize called for action", :get, :show do
      let(:record) { :churn }
    end

    it "renders churn data with the supplied dates" do
      expect(LargeSeller).to receive(:create_if_warranted).with(anything)
      expect(service).to receive(:generate_data).with(start_date: Date.new(2024, 1, 1), end_date: Date.new(2024, 2, 1)).and_return(churn_data)

      get :show, params: { from: "2024-01-01", to: "2024-02-01" }

      expect(response).to be_successful
      expect(inertia).to render_component("Churn/Show")
      expect(inertia.props[:churn]).to eq(churn_data)
    end

    it "passes nil dates when params are invalid" do
      expect(LargeSeller).to receive(:create_if_warranted).with(anything)
      expect(service).to receive(:generate_data).with(start_date: nil, end_date: nil).and_return(churn_data)

      get :show, params: { from: "bad", to: "" }

      expect(response).to be_successful
    end

    describe "payment requirements" do
      let!(:merchant_account) { create(:merchant_account, user: seller) }
      let(:stripe_account) { double }

      before do
        $redis.sadd(RedisKey.user_ids_with_payment_requirements_key, seller.id)
        allow(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id).and_return(stripe_account)
        allow(stripe_account).to receive(:capabilities).and_return(capabilities)
      end

      after do
        $redis.srem(RedisKey.user_ids_with_payment_requirements_key, seller.id)
      end

      context "when user is not part of payment requirements" do
        let(:capabilities) { {} }

        before do
          $redis.srem(RedisKey.user_ids_with_payment_requirements_key, seller.id)
        end

        it "does not redirect to payout settings" do
          get :show

          expect(response).to_not redirect_to(settings_payments_path)
        end
      end

      context "when compliance info is requested" do
        let(:capabilities) { {} }

        before do
          create(:user_compliance_info_request, user: seller, state: :requested)
        end

        it "redirects to payout settings" do
          expect(service).not_to receive(:generate_data)

          get :show

          expect(response).to redirect_to(settings_payments_path)
          expect(flash[:notice]).to eq("Urgent: We are required to collect more information from you to continue processing payments.")
        end
      end

      context "when capabilities are missing" do
        let(:capabilities) { {} }

        it "redirects to payout settings" do
          expect(service).not_to receive(:generate_data)

          get :show

          expect(response).to redirect_to(settings_payments_path)
          expect(flash[:notice]).to eq("Urgent: We are required to collect more information from you to continue processing payments.")
        end
      end

      context "when capabilities are satisfied" do
        let(:capabilities) do
          StripeMerchantAccountManager::REQUESTED_CAPABILITIES.index_with { |capability| "active" }
        end

        it "clears the redis flag and renders churn data" do
          expect(LargeSeller).to receive(:create_if_warranted).with(anything)
          expect(service).to receive(:generate_data).with(start_date: nil, end_date: nil).and_return(churn_data)

          get :show

          expect(response).to be_successful
          expect($redis.sismember(RedisKey.user_ids_with_payment_requirements_key, seller.id)).to be(false)
          expect(inertia).to render_component("Churn/Show")
          expect(inertia.props[:churn]).to eq(churn_data)
        end
      end
    end
  end
end
