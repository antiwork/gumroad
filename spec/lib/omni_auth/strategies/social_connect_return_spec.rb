# frozen_string_literal: true

require "spec_helper"

[OmniAuth::Strategies::Youtube, OmniAuth::Strategies::Instagram].each do |strategy_class|
  describe strategy_class do
    let(:strategy) { described_class.new(->(_env) { [200, {}, ["ok"]] }) }
    let(:user) { create(:user) }
    let(:token) { "test-navigation-token" }

    %w[request callback].each do |phase|
      it "routes a gated onboarding #{phase} through the existing failure endpoint with saved intent" do
        env = Rack::MockRequest.env_for("/users/auth/#{strategy.options.name}#{phase == 'callback' ? '/callback' : ''}")
        env["warden"] = instance_double(Warden::Proxy, user:)
        env["rack.session"] = phase == "request" ? { "omniauth.params" => { "social_connect_return" => token } } : {}
        env["omniauth.params"] = { "social_connect_return" => token } if phase == "callback"
        strategy.instance_variable_set(:@env, env)
        expect(strategy).to receive(:fail!).with(:social_connect_unavailable) do
          expect(env["omniauth.params"]).to eq("social_connect_return" => token)
          [302, { "Location" => "/dashboard" }, []]
        end
        strategy.public_send("#{phase}_phase")
        expect(env["rack.session"]["omniauth.params"]).to be_nil
      end
    end
  end
end
