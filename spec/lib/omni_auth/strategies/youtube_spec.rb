# frozen_string_literal: true

require "spec_helper"

describe OmniAuth::Strategies::Youtube do
  let(:app) { ->(_env) { [200, {}, ["ok"]] } }
  let(:strategy) { described_class.new(app) }

  def assign_env(user)
    warden = instance_double(Warden::Proxy, user:)
    strategy.instance_variable_set(:@env, { "warden" => warden })
  end

  describe "#youtube_connect_enabled?" do
    it "is false when the flag is off" do
      assign_env(create(:user))

      expect(strategy.send(:youtube_connect_enabled?)).to eq(false)
    end

    it "is true when the signed-in user has the flag" do
      user = create(:user)
      Feature.activate_user(:youtube_connect, user)
      assign_env(user)

      expect(strategy.send(:youtube_connect_enabled?)).to eq(true)
    end

    it "uses the impersonated seller as the flag actor" do
      admin = create(:admin_user)
      seller = create(:user)
      Feature.activate_user(:youtube_connect, seller)
      allow($redis).to receive(:get).with(RedisKey.impersonated_user(admin.id)).and_return(seller.id.to_s)
      assign_env(admin)

      expect(strategy.send(:youtube_connect_enabled?)).to eq(true)
    end
  end

  describe "#request_phase" do
    it "redirects to profile when the flag is off for a signed-in user" do
      assign_env(create(:user))

      status, headers, = strategy.request_phase

      expect(status).to eq(302)
      expect(headers["Location"]).to eq("/profile")
    end

    it "redirects to login when the flag is off and no user is signed in" do
      assign_env(nil)

      status, headers, = strategy.request_phase

      expect(status).to eq(302)
      expect(headers["Location"]).to eq("/login")
    end
  end
end
