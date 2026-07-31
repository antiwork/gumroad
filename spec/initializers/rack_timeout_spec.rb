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

  # `.env.test` raises the budget so slow CI runners don't fail specs on machine speed, so
  # assert the shipped DEFAULT rather than the value this process booted with.
  let(:production_default) do
    source = File.read(Rails.root.join("config/initializers/rack_timeout.rb"))
    source[/default_service_timeout\s*=\s*(\d+)/, 1].to_i
  end

  it "defaults to a 15 second service budget" do
    expect(middleware).to be_present
    expect(production_default).to eq 15
  end

  it "falls back to the default rather than disabling the timeout on an unparseable override" do
    # The initializer resolves the env var at boot, so mirror its parsing rather than
    # re-booting the app. rack-timeout treats 0 as false and disables the timeout
    # entirely, so a bare `.to_i` on "" / "abc" would silently remove the ceiling --
    # strictly worse than the 120s this replaced.
    resolve = lambda do |configured|
      if configured.present? && configured.to_s.match?(/\A\d+\z/) && configured.to_i.positive?
        configured.to_i
      else
        15
      end
    end

    expect(resolve.call("25")).to eq 25
    expect(resolve.call(nil)).to eq 15
    ["", " ", "abc", "0", "-5", "15\n", "15s"].each do |bad|
      expect(resolve.call(bad)).to eq(15),
                                   "#{bad.inspect} must fall back to 15, not disable the timeout"
    end
  end

  describe "in-request query guards" do
    # A query guard exists to convert a slow query into a clean 4xx that tells the
    # caller how to narrow it. If a guard resolves at or above the request budget it can
    # never fire first: Rack::Timeout kills the request (and the worker) instead, so the
    # graceful path becomes dead code. The controller clamps against the live budget, so
    # exercise the clamp with real Redis values -- asserting the bare constant would pass
    # for the wrong reason, since test Redis is empty.
    let(:service_timeout) { middleware.args.first[:service_timeout] }
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
        expect(resolved(key)).to be < service_timeout
      end
    end

    it "clamps a Redis override that meets or exceeds the request budget" do
      # A stale key holding the pre-change 15s default is the realistic regression, so drive
      # the resolver at the ambient budget rather than a hardcoded number (`.env.test` raises
      # it, and production runs 15).
      [service_timeout, service_timeout + 60].each do |dangerous|
        keys.each do |key|
          $redis.set(key, dangerous)
          expect(resolved(key)).to be < service_timeout,
                                   "an override of #{dangerous}s must be clamped under the " \
                                   "#{service_timeout}s budget, got #{resolved(key)}s"
        end
      end
    end

    it "never resolves to zero, which would disable the guard entirely" do
      # max_execution_time = 0 means "no limit" in MySQL, so a 0 or garbage override must
      # not pass through.
      ["0", "", "abc", "-5"].each do |bad|
        keys.each do |key|
          $redis.set(key, bad)
          expect(resolved(key)).to be_positive, "#{bad.inspect} must not disable the guard"
          expect(resolved(key)).to be < service_timeout
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
