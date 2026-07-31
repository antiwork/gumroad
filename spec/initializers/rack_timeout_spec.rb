# frozen_string_literal: true

require "spec_helper"

describe "Rack::Timeout configuration" do
  # The service timeout is the ceiling on how long one request may hold a Puma slot.
  # Production runs 6 workers x 2 threads = 12 slots per host, and sets
  # RACK_TIMEOUT_TERM_ON_TIMEOUT=1, so every timeout also SIGTERMs the worker. Both
  # facts make this value load-bearing for fleet capacity, not just for one request.
  let(:middleware) do
    Rails.application.config.middleware.find { |m| m.klass == Rack::Timeout }
  end

  it "installs Rack::Timeout with a 15 second service budget" do
    expect(middleware).to be_present
    expect(middleware.args.first[:service_timeout]).to eq 15
  end

  it "reads the budget from RACK_TIMEOUT_SERVICE_TIMEOUT so it can be tuned without a deploy" do
    # The initializer resolves the env var at boot; assert the contract rather than
    # re-booting the app, which a request spec cannot do.
    expect(File.read(Rails.root.join("config/initializers/rack_timeout.rb")))
      .to include('ENV["RACK_TIMEOUT_SERVICE_TIMEOUT"]')
  end

  describe "in-request query guards" do
    # A query guard exists to convert a slow query into a clean 4xx that tells the
    # caller how to narrow it. If a guard is set at or above the request budget it can
    # never fire first: Rack::Timeout kills the request (and the worker) instead, so
    # the graceful path becomes dead code. Every in-request guard must stay strictly
    # below the budget.
    let(:service_timeout) { middleware.args.first[:service_timeout] }

    it "keeps the API v2 sales guards strictly below the request budget" do
      [
        RedisKey.api_v2_sales_page_key_query_timeout,
        RedisKey.api_v2_sales_deprecated_pagination_query_timeout,
      ].each do |key|
        default = Api::V2::SalesController::QUERY_TIMEOUT_DEFAULT_SECONDS
        configured = ($redis.get(key) || default).to_i

        expect(configured).to be < service_timeout,
                              "#{key} is #{configured}s against a #{service_timeout}s request budget; " \
                              "the guard can never fire before Rack::Timeout kills the worker."
      end
    end
  end
end
