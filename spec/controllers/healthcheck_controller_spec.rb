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

  describe "GET 'deploy_safe'" do
    after { $redis.del(RedisKey.jobs_holding_deploys, RedisKey.legacy_payout_batch_in_flight) }

    context "when nothing is in flight (Redis key absent)" do
      it "returns 200" do
        $redis.del(RedisKey.jobs_holding_deploys)

        get :deploy_safe

        expect(response.status).to eq(200)
        expect(response.body).to eq("Deploy safety: no job in flight")
      end
    end

    context "when a job is in flight (a fresh entry exists)" do
      it "returns 503" do
        $redis.zadd(RedisKey.jobs_holding_deploys, Time.current.to_i, "job-token")

        get :deploy_safe

        expect(response.status).to eq(503)
        expect(response.body).to eq("Deploy safety: job in flight")
      ensure
        $redis.del(RedisKey.jobs_holding_deploys)
      end
    end

    context "when the only entries are older than the per-entry TTL (job died mid-run)" do
      it "returns 200 and prunes the stale entry" do
        stale_score = (HoldsDeployWhileRunning::IN_FLIGHT_ENTRY_TTL + 1.minute).ago.to_i
        $redis.zadd(RedisKey.jobs_holding_deploys, stale_score, "dead-job-token")

        get :deploy_safe

        expect(response.status).to eq(200)
        expect($redis.zcard(RedisKey.jobs_holding_deploys)).to eq(0)
      ensure
        $redis.del(RedisKey.jobs_holding_deploys)
      end
    end

    context "when a stale entry sits alongside a fresh one" do
      it "returns 503 and prunes only the stale entry" do
        stale_score = (HoldsDeployWhileRunning::IN_FLIGHT_ENTRY_TTL + 1.minute).ago.to_i
        $redis.zadd(RedisKey.jobs_holding_deploys, stale_score, "dead-job-token")
        $redis.zadd(RedisKey.jobs_holding_deploys, Time.current.to_i, "live-job-token")

        get :deploy_safe

        expect(response.status).to eq(503)
        expect($redis.zscore(RedisKey.jobs_holding_deploys, "dead-job-token")).to be_nil
        expect($redis.zscore(RedisKey.jobs_holding_deploys, "live-job-token")).to be_present
      ensure
        $redis.del(RedisKey.jobs_holding_deploys)
      end
    end

    context "when the in-flight job predates this change and only wrote the legacy key" do
      it "returns 503, so a payout batch started on the previous release still holds deploys" do
        $redis.zadd(RedisKey.legacy_payout_batch_in_flight, Time.current.to_i, "old-code-payout-token")

        get :deploy_safe

        expect(response.status).to eq(503)
        expect(response.body).to eq("Deploy safety: job in flight")
      end
    end

    context "when the legacy key holds only an entry older than the per-entry TTL" do
      it "returns 200 and prunes it, so a dead old-code job cannot freeze deploys" do
        stale_score = (HoldsDeployWhileRunning::IN_FLIGHT_ENTRY_TTL + 1.minute).ago.to_i
        $redis.zadd(RedisKey.legacy_payout_batch_in_flight, stale_score, "dead-old-code-token")

        get :deploy_safe

        expect(response.status).to eq(200)
        expect($redis.zcard(RedisKey.legacy_payout_batch_in_flight)).to eq(0)
      end
    end

    context "when a live entry in one key sits alongside a stale entry in the other" do
      it "prunes both keys rather than stopping at the first live one" do
        stale_score = (HoldsDeployWhileRunning::IN_FLIGHT_ENTRY_TTL + 1.minute).ago.to_i
        $redis.zadd(RedisKey.jobs_holding_deploys, Time.current.to_i, "live-job-token")
        $redis.zadd(RedisKey.legacy_payout_batch_in_flight, stale_score, "dead-old-code-token")

        get :deploy_safe

        expect(response.status).to eq(503)
        expect($redis.zscore(RedisKey.legacy_payout_batch_in_flight, "dead-old-code-token")).to be_nil
      end
    end

    context "when requested at the legacy /healthcheck/payouts path" do
      it "answers the same, so a deploy script from before the rename still gets a verdict" do
        $redis.zadd(RedisKey.jobs_holding_deploys, Time.current.to_i, "job-token")

        get :deploy_safe, params: {}

        expect(response.status).to eq(503)
        expect(Rails.application.routes.recognize_path("/healthcheck/payouts"))
          .to include(controller: "healthcheck", action: "deploy_safe")
      ensure
        $redis.del(RedisKey.jobs_holding_deploys)
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
        allow(StagingApplePayDomainRegistration).to receive(:applicable?).and_return(true)
      end

      it "reports an active registration" do
        allow(StagingApplePayDomainRegistration).to receive(:register!)
          .and_return(StagingApplePayDomainRegistration::Result.new(active: true, message: "Apple Pay on my-branch.apps.staging.gumroad.org: active"))

        get :apple_pay_domain

        expect(response.status).to eq(200)
        expect(response.body).to eq("Apple Pay on my-branch.apps.staging.gumroad.org: active")
      end

      it "reports an inactive registration as service_unavailable" do
        allow(StagingApplePayDomainRegistration).to receive(:register!)
          .and_return(StagingApplePayDomainRegistration::Result.new(active: false, message: "Apple Pay on my-branch.apps.staging.gumroad.org: inactive — Domain verification failed"))

        get :apple_pay_domain

        expect(response.status).to eq(503)
        expect(response.body).to eq("Apple Pay on my-branch.apps.staging.gumroad.org: inactive — Domain verification failed")
      end

      it "reports Stripe errors as service_unavailable" do
        allow(StagingApplePayDomainRegistration).to receive(:register!).and_raise(Stripe::InvalidRequestError.new("verification failed", nil))

        get :apple_pay_domain

        expect(response.status).to eq(503)
        expect(response.body).to eq("Apple Pay domain registration failed: verification failed")
      end
    end
  end
end
