# frozen_string_literal: true

require "spec_helper"

describe HomeController do
  render_views

  before { allow(GithubStarsController).to receive(:cached_count).and_return(1234) }

  describe "GET about" do
    it "renders the figure held in Redis" do
      $redis.set(RedisKey.prev_week_payout_usd, "424242")

      get :about

      expect(response).to be_successful
      expect(response.body).to include("$424,242")
    end

    it "renders the default figure instead of failing when the Redis read times out" do
      allow($redis).to receive(:get).and_call_original
      allow($redis).to receive(:get).with(RedisKey.prev_week_payout_usd)
        .and_raise(RedisClient::ReadTimeoutError.new("Waited 1.0 seconds"))

      get :about

      expect(response).to be_successful
      expect(response.body).to include("$3,129,297")
    end
  end

  describe "GET features_md" do
    it "returns markdown with the feature list" do
      get :features_md

      expect(response).to be_successful
      expect(response.content_type).to include("text/markdown")
      expect(response.body).to include("# Gumroad features")
      expect(response.body).to include("Digital products")
      expect(response.body).to include("Memberships")
      expect(response.body).to include("REST API")
    end
  end

  describe "GET small_bets" do
    it "renders successfully" do
      get :small_bets

      expect(response).to be_successful
      expect(controller.send(:page_title)).to eq("Small Bets by Gumroad")
      expect(assigns(:hide_layouts)).to be(true)
    end
  end

  describe "GET saas" do
    it "renders successfully" do
      get :saas

      expect(response).to be_successful
      expect(controller.send(:page_title)).to include("Gumroad for SaaS")
      expect(assigns(:hide_layouts)).to be(true)
    end
  end

  describe "GET dpa" do
    it "renders successfully" do
      get :dpa

      expect(response).to be_successful
      expect(controller.send(:page_title)).to eq("Gumroad data processing addendum")
      expect(response.body).to include("Data Processing")
      expect(response.body).to include("Subprocessors")
      expect(response.body).to include("International Transfers")
    end
  end
end
