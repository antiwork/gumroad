# frozen_string_literal: true

require "spec_helper"

describe Api::Internal::HomePageNumbersController do
  context "when the return value is cached" do
    let(:cached_value) do
      {
        prev_week_payout_usd: "$37,537"
      }
    end

    before do
      Rails.cache.write("homepage_numbers", cached_value)
    end

    it "returns the cached result as JSON" do
      get :index

      expect(response).to be_successful
      expect(response.parsed_body).to eq(cached_value.as_json)
    end
  end

  context "when the return value is not cached" do
    let(:expected_value) do
      {
        prev_week_payout_usd: "$37,437"
      }
    end

    before do
      $redis.set(RedisKey.prev_week_payout_usd, "37437")
    end

    it "fetches the values from HomePagePresenter" do
      get :index

      expect(response).to be_successful
      expect(response.parsed_body).to eq(expected_value.as_json)
    end
  end

  context "when the Redis read stalls" do
    before do
      Rails.cache.delete("homepage_numbers")
      allow($redis).to receive(:get).and_call_original
      allow($redis).to receive(:get).with(RedisKey.prev_week_payout_usd)
        .and_raise(RedisClient::Error.new("Waited 1.0 seconds"))
    end

    it "returns the same blank figure an unset key gives instead of failing" do
      get :index

      expect(response).to be_successful
      expect(response.parsed_body).to eq({ "prev_week_payout_usd" => "$" })
      # A degraded figure must not be published and remembered for a day on the homepage.
      expect(Rails.cache.read("homepage_numbers")).to be_nil
    end
  end

  context "when the payout key is unset" do
    before do
      Rails.cache.delete("homepage_numbers")
      $redis.del(RedisKey.prev_week_payout_usd)
    end

    it "caches the blank figure a real unset-key read gives" do
      allow($redis).to receive(:get).and_call_original
      get :index

      expect(response.parsed_body).to eq({ "prev_week_payout_usd" => "$" })
      expect(Rails.cache.read("homepage_numbers")).to be_present

      get :index

      # Served from the cache written by the unset read, not read from Redis again: one read total,
      # from the first request.
      expect(response.parsed_body).to eq({ "prev_week_payout_usd" => "$" })
      expect($redis).to have_received(:get).with(RedisKey.prev_week_payout_usd).once
    end
  end
end
