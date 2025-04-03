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
    routes.draw { get :action, to: "anonymous#action" }
    allow(GlobalConfig).to receive(:get).with("HELPER_WIDGET_SECRET").and_return("test_secret")
  end

  describe "#helper_widget_host" do
    it "returns the default host when environment variable is not set" do
      expect(ENV["HELPER_WIDGET_HOST"]).to be_nil
      expect(controller.helper_widget_host).to eq("https://helper.ai")
    end

    it "returns the environment variable value when set" do
      allow(ENV).to receive(:fetch).with("HELPER_WIDGET_HOST", "https://helper.ai").and_return("https://custom.helper.ai")
      expect(controller.helper_widget_host).to eq("https://custom.helper.ai")
    end
  end

  describe "#show_helper_widget?" do
    context "when conditions are met" do
      before do
        allow(Rails.env).to receive(:test?).and_return(false)
        allow(Feature).to receive(:active?).with(:helper_widget, user).and_return(true)
        stub_const("DOMAIN", "gumroad.com")
        sign_in(user)
        request.host = "gumroad.com"
      end

      it "returns true" do
        get :action
        expect(controller.show_helper_widget?).to be true
      end
    end

    context "when in test environment" do
      before do
        allow(Rails.env).to receive(:test?).and_return(true)
      end

      it "returns false" do
        get :action
        expect(controller.show_helper_widget?).to be false
      end
    end

    context "when domain is not gumroad.com" do
      before do
        allow(Rails.env).to receive(:test?).and_return(false)
        allow(Feature).to receive(:active?).with(:helper_widget, user).and_return(true)
        sign_in(user)
        request.host = "seller.gumroad.com"
      end

      it "returns false" do
        get :action
        expect(controller.show_helper_widget?).to be false
      end
    end

    context "when feature is not active" do
      before do
        allow(Rails.env).to receive(:test?).and_return(false)
        allow(Feature).to receive(:active?).with(:helper_widget, user).and_return(false)
        sign_in(user)
        request.host = "gumroad.com"
      end

      it "returns false" do
        get :action
        expect(controller.show_helper_widget?).to be false
      end
    end
  end

  describe "#helper_widget_email_hmac" do
    before do
      sign_in(seller)
    end

    it "generates the correct HMAC" do
      timestamp = "1234567890"
      expected_hmac = OpenSSL::HMAC.hexdigest("sha256", "test_secret", "#{seller.email}:#{timestamp}")
      expect(controller.helper_widget_email_hmac(timestamp)).to eq(expected_hmac)
    end
  end
end
