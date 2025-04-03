# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe AnalyticsController do
  render_views

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { :analytics }
    end

    context "stripe connect requirements" do
      before do
        create(:merchant_account, user: seller)
        $redis.sadd(RedisKey.user_ids_with_payment_requirements_key, seller.id)
        @stripe_account = double
        allow(Stripe::Account).to receive(:retrieve).and_return(@stripe_account)
      end

      it "does not redirect to payout settings page if user not part of user_ids_with_payment_requirements_key" do
        $redis.srem(RedisKey.user_ids_with_payment_requirements_key, seller.id)

        get :index

        expect(response).to_not redirect_to(settings_payments_path)
      end

      it "redirects to payout settings page if compliance requests exist" do
        create(:user_compliance_info_request, user: seller, state: :requested)

        get :index

        expect(response).to redirect_to(settings_payments_path)
        expect(flash[:notice]).to eq("Urgent: We are required to collect more information from you to continue processing payments.")
      end

      it "redirects to payout settings page if capabilities missing" do
        allow(@stripe_account).to receive(:capabilities).and_return({})
        get :index

        expect(response).to redirect_to(settings_payments_path)
        expect(flash[:notice]).to eq("Urgent: We are required to collect more information from you to continue processing payments.")
      end

      it "removes from users that need requirements if capabilities are satisfied" do
        allow(@stripe_account).to receive(:capabilities).and_return({ card_payments: "active",
                                                                      legacy_payments: "active",
                                                                      transfers: "active" })

        get :index

        expect(response).to_not redirect_to(settings_payments_path)
        expect($redis.sismember(RedisKey.user_ids_with_payment_requirements_key, seller.id)).to eq(false)
      end
    end

    describe "when user is not qualified for analytics" do
      before :each do
        allow(controller.logged_in_user).to receive(:visible).and_return([])
        allow(controller.logged_in_user).to receive(:successful_or_preorder_authorization_successful).and_return([])
      end

      it "assigns props" do
        get :index
        expect(assigns(:analytics_props)).to_not be(nil)
      end
    end

    describe "when user is qualified for analytics" do
      before :each do
        allow(controller.logged_in_user).to receive(:visible).and_return([Link.new])
        allow(controller.logged_in_user).to receive(:successful_or_preorder_authorization_successful).and_return([Purchase.new])
        product = create(:product, user: seller)
        create(:purchase, link: product, price_cents: 100, purchase_state: "successful")
      end

      it "sets the last viewed dashboard cookie" do
        get :index

        expect(response.cookies["last_viewed_dashboard"]).to eq "sales"
      end

      it "assigns props" do
        get :index
        expect(assigns(:analytics_props)).to_not be(nil)
      end

      it "does not call prepare_demo" do
        expect(controller).to_not receive(:prepare_demo)
        get :index
      end

      it "attemps to create related LargeSeller record" do
        expect(LargeSeller).to receive(:create_if_warranted).with(controller.current_seller)
        get :index
      end
    end
  end

  shared_examples "supports start and end times" do |action_name|
    it "assigns the correct @start_date and @end_date" do
      get(action_name, params: {
            start_time: "Tue May 25 2021 14:32:31 GMT 0700 (Novosibirsk Standard Time)",
            end_time: "Wed Jun 23 2021 14:32:31 GMT 0700 (Novosibirsk Standard Time)",
          })
      expect(assigns(:start_date)).to eq(Date.new(2021, 5, 25))
      expect(assigns(:end_date)).to eq(Date.new(2021, 6, 23))
    end
  end

  describe "GET data_by_date" do
    before do
      @stats = { data: "data" }
    end

    it_behaves_like "supports start and end times", :data_by_date

    it_behaves_like "authorize called for action", :get, :data_by_date do
      let(:record) { :analytics }
      let(:policy_method) { :index? }
    end

    describe "when start_time and end_time are valid" do
      it "gets analytics stats range from start_time to end_time" do
        start_time = "Mon Apr 8 2013 22:40:18 GMT-0700 (PDT)"
        end_time = "Wed Apr 10 2013 22:40:18 GMT-0700 (PDT)"
        expected_start_time = Date.parse(start_time)
        expected_end_time = Date.parse(end_time)
        expect_any_instance_of(CreatorAnalytics::CachingProxy).to receive(:data_for_dates).with(expected_start_time, expected_end_time, by: :date).and_return(@stats)
        get :data_by_date, params: { start_time:, end_time: }
        expect(response.body).to eq(@stats.to_json)
      end

      it "renders stats in json format" do
        get :data_by_date
      end
    end

    describe "when start_time or end_time is invalid" do
      it "gets analytics stats range from 29 days ago to today" do
        now = DateTime.current
        allow(Date).to receive(:now).and_return(now)
        expected_start_time = now.to_date.ago(29.days)
        expected_end_time = now.to_date
        expect_any_instance_of(CreatorAnalytics::CachingProxy).to receive(:data_for_dates).with(expected_start_time, expected_end_time, by: :date).and_return(@stats)
        get :data_by_date
        expect(response.body).to eq(@stats.to_json)
      end
    end
  end
end
