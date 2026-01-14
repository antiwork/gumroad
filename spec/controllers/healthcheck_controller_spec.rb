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

  shared_examples "sidekiq healthcheck" do |queue_type, queue_name, limit|
    context "#{queue_type} queues" do
      before do
        if queue_name.nil?
          allow(queue_class).to receive(:new).and_return(queue_double)
        else
          allow(queue_class).to receive(:new).with(queue_name).and_return(queue_double)
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
    end

    describe "Sidekiq retry set" do
      it_behaves_like "sidekiq healthcheck", :retry_set, nil, 20_000 do
        let(:queue_class) { Sidekiq::RetrySet }
      end
    end

    describe "Sidekiq dead set" do
      it_behaves_like "sidekiq healthcheck", :retry_set, nil, 10_000 do
        let(:queue_class) { Sidekiq::DeadSet }
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
end
