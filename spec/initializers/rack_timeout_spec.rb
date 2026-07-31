# frozen_string_literal: true

require "spec_helper"

describe BudgetedRequestTimeout do
  # The service timeout is the ceiling on how long one request may hold a Puma slot.
  # Production runs 6 workers x 2 threads = 12 slots per host, and sets
  # RACK_TIMEOUT_TERM_ON_TIMEOUT=1, so every timeout also SIGTERMs the worker. Both
  # facts make this value load-bearing for fleet capacity, not just for one request.
  describe "budgets" do
    it "defaults the general web budget to 15 seconds and checkout to 120" do
      expect(described_class::Budget::GENERAL_DEFAULT_SECONDS).to eq 15
      expect(described_class::Budget::CHECKOUT_DEFAULT_SECONDS).to eq 120
    end

    it "is installed in the middleware stack" do
      expect(Rails.application.config.middleware.find { _1.klass == described_class }).to be_present
    end

    it "falls back to the default rather than disabling the timeout on an unparseable override" do
      # rack-timeout treats 0 as false and disables the timeout entirely, so a bare `.to_i` on
      # "" / "abc" would silently remove the ceiling -- strictly worse than the 120s this replaced.
      ["", " ", "abc", "0", "-5", "15\n", "15s"].each do |bad|
        stub_const("ENV", ENV.to_h.merge("RACK_TIMEOUT_SERVICE_TIMEOUT" => bad))
        expect(described_class::Budget.general).to eq(15), "#{bad.inspect} must fall back to 15, not disable the timeout"
      end
    end

    it "rejects a budget below the in-request guard headroom" do
      # A 1s budget leaves no room for a guard to fire first: the sales query cap would resolve
      # to the same second as the request deadline and the graceful 400 would become unreachable.
      stub_const("ENV", ENV.to_h.merge("RACK_TIMEOUT_SERVICE_TIMEOUT" => "1"))
      expect(described_class::Budget.general).to eq 15

      stub_const("ENV", ENV.to_h.merge("RACK_TIMEOUT_SERVICE_TIMEOUT" => "2"))
      expect(described_class::Budget.general).to eq 2
    end

    it "honours a legitimate override on either budget" do
      stub_const("ENV", ENV.to_h.merge("RACK_TIMEOUT_SERVICE_TIMEOUT" => "30",
                                       "RACK_TIMEOUT_CHECKOUT_SERVICE_TIMEOUT" => "90"))
      expect(described_class::Budget.general).to eq 30
      expect(described_class::Budget.checkout).to eq 90
    end

    it "never lets the checkout budget fall below the general one" do
      stub_const("ENV", ENV.to_h.merge("RACK_TIMEOUT_SERVICE_TIMEOUT" => "60",
                                       "RACK_TIMEOUT_CHECKOUT_SERVICE_TIMEOUT" => "20"))
      expect(described_class::Budget.checkout).to eq 60
    end
  end

  describe ".extended_budget_path?" do
    # These paths call the payment processor and only record local success afterwards, so a
    # timeout between the two leaves the buyer charged with a purchase marked failed.
    it "matches the paths that create or finalize a charge" do
      [
        "/orders",
        "/orders/prepare",
        "/orders/abc123/confirm",
        "/orders/abc123/finalize",
        "/checkout/returns/abc123",
        "/purchases/abc123/confirm",
        "/service_charges",
        "/service_charges/abc123/confirm",
        "/preorders/abc123/charge_preorder",
        "/subscriptions/abc123",
      ].each do |path|
        expect(described_class.extended_budget_path?(path)).to be(true), "#{path} must get the checkout budget"
      end
    end

    it "does not match ordinary web paths" do
      [
        "/",
        "/discover",
        "/l/some-product",
        "/orders_history",
        "/checkout",
        "/purchases/abc123/receipt",
        "/purchases/abc123/subscribe",
        "/library",
        "/service_charges_report",
        "/subscriptions/abc123/manage",
        nil,
        "",
      ].each do |path|
        expect(described_class.extended_budget_path?(path)).to be(false), "#{path.inspect} must get the general budget"
      end
    end
  end

  describe "routing a request to the right budget" do
    # Assert the budget the gem actually applied to the request (it records the computed value in
    # env under `rack-timeout.info`), not just which regex matched — otherwise deleting the
    # dispatch line and letting every request take the short budget would still pass.
    let(:captured) { [] }
    let(:app) { ->(env) { captured << env[Rack::Timeout::ENV_INFO_KEY].timeout; [200, {}, ["ok"]] } }
    # `.env.test` raises the general budget to 120 so slow runners don't fail specs on machine
    # speed, which would collapse the two budgets into one here. Build this instance at the
    # production shape instead.
    let(:middleware) do
      stub_const("ENV", ENV.to_h.merge("RACK_TIMEOUT_SERVICE_TIMEOUT" => "15"))
      described_class.new(app, wait_timeout: false)
    end

    def applied_budget(path)
      status, _headers, body = middleware.call(Rack::MockRequest.env_for(path))
      expect(status).to eq 200
      expect(body).to eq ["ok"]
      captured.last
    end

    it "gives checkout the longer budget and everything else the short one" do
      expect(applied_budget("/orders/abc123/confirm")).to eq described_class::Budget.checkout
      expect(applied_budget("/checkout/returns/abc123")).to eq described_class::Budget.checkout
      expect(applied_budget("/l/some-product")).to eq 15
      expect(applied_budget("/orders/abc123/confirm")).to be > applied_budget("/l/some-product")
    end
  end

  describe "in-request query guards" do
    # A query guard exists to convert a slow query into a clean 4xx that tells the caller how to
    # narrow it. If a guard resolves at or above the request budget it can never fire first:
    # Rack::Timeout kills the request (and the worker) instead, so the graceful path becomes dead
    # code. The controller clamps against the live budget, so exercise the clamp with real Redis
    # values -- asserting the bare constant would pass for the wrong reason, since test Redis is empty.
    let(:budget) { described_class::Budget.general }
    let(:controller) { Api::V2::SalesController.new }
    let(:keys) do
      [
        RedisKey.api_v2_sales_page_key_query_timeout,
        RedisKey.api_v2_sales_deprecated_pagination_query_timeout,
      ]
    end

    def resolved(key) = controller.send(:query_timeout_seconds, key)

    after { keys.each { $redis.del(_1) } }

    it "defaults below the request budget" do
      keys.each do |key|
        expect(resolved(key)).to eq Api::V2::SalesController::QUERY_TIMEOUT_DEFAULT_SECONDS
        expect(resolved(key)).to be < budget
      end
    end

    it "clamps a Redis override that meets or exceeds the request budget" do
      # A stale key holding the pre-change 15s default is the realistic regression, so drive the
      # resolver at the ambient budget rather than a hardcoded number (`.env.test` raises it, and
      # production runs 15).
      [budget, budget + 60].each do |dangerous|
        keys.each do |key|
          $redis.set(key, dangerous)
          expect(resolved(key)).to be < budget,
                                   "an override of #{dangerous}s must be clamped under the " \
                                   "#{budget}s budget, got #{resolved(key)}s"
        end
      end
    end

    it "stays under the budget even at the lowest budget the resolver accepts" do
      stub_const("ENV", ENV.to_h.merge("RACK_TIMEOUT_SERVICE_TIMEOUT" => "2"))
      keys.each do |key|
        $redis.set(key, 60)
        expect(resolved(key)).to eq 1
        expect(resolved(key)).to be < described_class::Budget.general
      end
    end

    it "never resolves to zero, which would disable the guard entirely" do
      # max_execution_time = 0 means "no limit" in MySQL, so a 0 or garbage override must not
      # pass through.
      ["0", "", "abc", "-5"].each do |bad|
        keys.each do |key|
          $redis.set(key, bad)
          expect(resolved(key)).to be_positive, "#{bad.inspect} must not disable the guard"
          expect(resolved(key)).to be < budget
        end
      end
    end

    it "honours a legitimate lower override" do
      keys.each do |key|
        $redis.set(key, 3)
        expect(resolved(key)).to eq 3
      end
    end
  end
end
