# frozen_string_literal: true

require "spec_helper"

describe HelperWidget, type: :controller do
  controller(ApplicationController) do
    include HelperWidget

    def action
      head :ok
    end
  end

  let(:seller) { create(:named_seller, email: "test@example.com") }
  let(:user) { create(:user) }

  before do
    routes.draw { get ":action", controller: "anonymous" }

    allow(GlobalConfig).to receive(:get).with("HELPER_WIDGET_SECRET").and_return("test_secret")
  end

  describe "#helper_widget_host" do
    it "returns nil when config is not set" do
      allow(GlobalConfig).to receive(:get).with("HELPER_WIDGET_HOST").and_return(nil)
      expect(controller.helper_widget_host).to be_nil
    end

    it "returns the config value when set" do
      allow(GlobalConfig).to receive(:get).with("HELPER_WIDGET_HOST").and_return("https://custom.helper.ai")
      expect(controller.helper_widget_host).to eq("https://custom.helper.ai")
    end
  end

  describe "#helper_session" do
    it "returns nil when no seller is signed in" do
      expect(controller.helper_session).to be_nil
    end

    it "returns email, emailHash and timestamp when signed in" do
      sign_in(seller)

      fixed_time = Time.zone.parse("2024-01-01 00:00:00 UTC")
      allow(Time).to receive(:current).and_return(fixed_time)
      timestamp_ms = (fixed_time.to_f * 1000).to_i

      expected_hmac = OpenSSL::HMAC.hexdigest("sha256", "test_secret", "#{seller.email}:#{timestamp_ms}")

      session = controller.helper_session

      expect(session[:email]).to eq(seller.email)
      expect(session[:emailHash]).to eq(expected_hmac)
      expect(session[:timestamp]).to eq(timestamp_ms)
    end
  end
end
