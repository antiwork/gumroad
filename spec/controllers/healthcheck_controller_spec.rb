# frozen_string_literal: true

require "spec_helper"

describe HealthcheckController do
  describe "GET 'index'" do
    it "returns 'healthcheck' as text" do
      get :index

      expect(response.status).to eq(200)
      expect(response.body).to eq("healthcheck")
    end
  end

  SIDEKIQ_QUEUE_NAMES = [:critical, :default].freeze

  shared_examples "sidekiq healthcheck" do |queue_type, queue_name, limit|
    context "#{queue_type} queues" do
      before do
        if queue_name.nil?
          allow(queue_class).to receive(:new).and_return(queue_double)
        else
          allow(queue_class).to receive(:new).with(queue_name).and_return(queue_double)
          (SIDEKIQ_QUEUE_NAMES - [queue_name]).each do |other_name|
            other_double = double("queue #{other_name} double", size: 0)
            allow(queue_class).to receive(:new).with(other_name).and_return(other_double)
          end
        end
      end

      let(:queue_double) { double("#{queue_type} double") }

      it "returns HTTP success when the jobs count is under limit" do
        allow(queue_double).to receive(:size).and_return(limit - 1)

        get :sidekiq

        expect(response.status).to eq(200)
        expect(response.body).to eq("Sidekiq: ok")
      end

      it "returns HTTP service_unavailable when the jobs count is over the limit" do
        allow(queue_double).to receive(:size).and_return(limit + 1)

        get :sidekiq

        expect(response.status).to eq(503)
        expect(response.body).to eq("Sidekiq: service_unavailable")
      end
    end
  end

  describe "GET 'sidekiq'" do
    describe "Sidekiq queues" do
      it_behaves_like "sidekiq healthcheck", :queue, :critical, 12_000 do
        let(:queue_class) { Sidekiq::Queue }
      end

      it_behaves_like "sidekiq healthcheck", :queue, :default, 300_000 do
        let(:queue_class) { Sidekiq::Queue }
      end
    end

    describe "Sidekiq retry set" do
      it_behaves_like "sidekiq healthcheck", :retry_set, nil, 20_000 do
        let(:queue_class) { Sidekiq::RetrySet }
      end
    end
  end

  describe "GET 'paypal_balance'" do
    context "when PayPal topup is not needed (Redis key is false)" do
      before do
        $redis.set(RedisKey.paypal_topup_needed, "false")
      end

      it "returns HTTP success" do
        get :paypal_balance

        expect(response.status).to eq(200)
        expect(response.body).to eq("PayPal balance: topup not required")
      end
    end

    context "when Redis key is not set" do
      before do
        $redis.del(RedisKey.paypal_topup_needed)
      end

      it "returns HTTP service_unavailable" do
        get :paypal_balance

        expect(response.status).to eq(503)
        expect(response.body).to eq("PayPal balance: topup required")
      end
    end

    context "when PayPal topup is needed (Redis key is true)" do
      before do
        $redis.set(RedisKey.paypal_topup_needed, "true")
      end

      it "returns HTTP service_unavailable" do
        get :paypal_balance

        expect(response.status).to eq(503)
        expect(response.body).to eq("PayPal balance: topup required")
      end
    end
  end

  describe "GET 'stripe_balance'" do
    context "when Stripe topup is not needed (Redis key is false)" do
      before do
        $redis.set(RedisKey.stripe_balance_topup_needed, "false")
      end

      it "returns HTTP success" do
        get :stripe_balance

        expect(response.status).to eq(200)
        expect(response.body).to eq("Stripe balance: topup not required")
      end
    end

    context "when Redis key is not set" do
      before do
        $redis.del(RedisKey.stripe_balance_topup_needed)
      end

      it "returns HTTP service_unavailable" do
        get :stripe_balance

        expect(response.status).to eq(503)
        expect(response.body).to eq("Stripe balance: topup required")
      end
    end

    context "when Stripe topup is needed (Redis key is true)" do
      before do
        $redis.set(RedisKey.stripe_balance_topup_needed, "true")
      end

      it "returns HTTP service_unavailable" do
        get :stripe_balance

        expect(response.status).to eq(503)
        expect(response.body).to eq("Stripe balance: topup required")
      end
    end
  end

  describe "GET 'purchases'" do
    let(:redis_key) { RedisKey.min_successful_purchases_in_last_10_minutes }

    after { $redis.del(redis_key) }

    context "when the successful purchases count meets the threshold" do
      before do
        $redis.set(redis_key, 2)
        create_list(:purchase, 2, purchase_state: "successful", created_at: 5.minutes.ago)
      end

      it "returns HTTP success" do
        get :purchases

        expect(response.status).to eq(200)
        expect(response.body).to eq("Purchases: ok")
      end
    end

    context "when the successful purchases count is below the threshold" do
      before do
        $redis.set(redis_key, 5)
        create_list(:purchase, 2, purchase_state: "successful", created_at: 5.minutes.ago)
      end

      it "returns HTTP service_unavailable" do
        get :purchases

        expect(response.status).to eq(503)
        expect(response.body).to eq("Purchases: service_unavailable")
      end
    end

    context "when successful purchases are older than 10 minutes" do
      before do
        $redis.set(redis_key, 1)
        create(:purchase, purchase_state: "successful", created_at: 15.minutes.ago)
      end

      it "ignores them and returns HTTP service_unavailable" do
        get :purchases

        expect(response.status).to eq(503)
        expect(response.body).to eq("Purchases: service_unavailable")
      end
    end

    context "when the Redis threshold is not set" do
      before { $redis.del(redis_key) }

      it "returns HTTP service_unavailable" do
        get :purchases

        expect(response.status).to eq(503)
        expect(response.body).to eq("Purchases: service_unavailable")
      end
    end
  end

  describe "GET 'apple_pay_domain'" do
    context "when not a staging branch deployment" do
      it "returns 404" do
        expect { get :apple_pay_domain }.to raise_error(ActionController::RoutingError)
      end
    end

    context "when running as a staging branch deployment" do
      before do
        allow(Rails.env).to receive(:staging?).and_return(true)
        stub_const("ENV", ENV.to_h.merge("BRANCH_DEPLOYMENT" => "true", "CUSTOM_DOMAIN" => "my-branch.apps.staging.gumroad.org"))
      end

      it "reports an already-registered domain" do
        domain_object = double(id: "apwc_123", livemode: false)
        allow(Stripe::ApplePayDomain).to receive(:list).with(domain_name: "my-branch.apps.staging.gumroad.org", limit: 1).and_return(double(data: [domain_object]))

        get :apple_pay_domain

        expect(response.status).to eq(200)
        expect(response.body).to eq("Apple Pay domain: registered (my-branch.apps.staging.gumroad.org, apwc_123, livemode=false)")
      end

      it "registers the domain when it is missing" do
        allow(Stripe::ApplePayDomain).to receive(:list).and_return(double(data: []))
        expect(Stripe::ApplePayDomain).to receive(:create).with(domain_name: "my-branch.apps.staging.gumroad.org").and_return(double(id: "apwc_456", livemode: false))

        get :apple_pay_domain

        expect(response.status).to eq(200)
        expect(response.body).to eq("Apple Pay domain: registered just now (my-branch.apps.staging.gumroad.org, apwc_456, livemode=false)")
      end

      it "reports Stripe errors as service_unavailable" do
        allow(Stripe::ApplePayDomain).to receive(:list).and_raise(Stripe::InvalidRequestError.new("verification failed", nil))

        get :apple_pay_domain

        expect(response.status).to eq(503)
        expect(response.body).to eq("Apple Pay domain: registration failed (my-branch.apps.staging.gumroad.org): verification failed")
      end
    end
  end
end
