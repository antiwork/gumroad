# frozen_string_literal: true

require "spec_helper"

describe HelperWidget, type: :controller do
  controller(ApplicationController) do
    include HelperWidget

    allow_anonymous_access_to_helper_widget only: :anonymous_access_allowed

    def action
      head :ok
    end

    def anonymous_access_allowed
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
    it "returns the default host when environment variable is not set" do
      expect(ENV["HELPER_WIDGET_HOST"]).to be_nil
      expect(controller.helper_widget_host).to eq("https://help.gumroad.com")
    end

    it "returns the environment variable value when set" do
      allow(ENV).to receive(:fetch).with("HELPER_WIDGET_HOST", "https://help.gumroad.com").and_return("https://custom.helper.ai")
      expect(controller.helper_widget_host).to eq("https://custom.helper.ai")
    end
  end

  describe "#show_helper_widget?" do
    context "when conditions are met" do
      before do
        allow(Rails.env).to receive(:test?).and_return(false)
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
        sign_in(user)
        request.host = "seller.gumroad.com"
      end

      it "returns false" do
        get :action
        expect(controller.show_helper_widget?).to be false
      end
    end

    describe "anonymous access" do
      before do
        allow(Rails.env).to receive(:test?).and_return(false)
        stub_const("DOMAIN", "gumroad.com")
        request.host = "gumroad.com"
      end

      context "feature is globally enabled" do
        before do
          Feature.activate(:anonymous_helper_widget_access)
        end

        it "returns true if anonymous access is allowed" do
          get :anonymous_access_allowed
          expect(controller.show_helper_widget?).to be true

          get :action
          expect(controller.show_helper_widget?).to be false
        end
      end

      context "feature is enabled via query param" do
        it "returns true" do
          get :action, params: { anonymous_helper_widget_access: true }
          expect(controller.show_helper_widget?).to be false

          get :action
          expect(controller.show_helper_widget?).to be false

          get :anonymous_access_allowed, params: { anonymous_helper_widget_access: true }
          expect(controller.show_helper_widget?).to be true

          get :anonymous_access_allowed
          expect(controller.show_helper_widget?).to be false
        end
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

  describe "#helper_widget_init_data", :freeze_time do
    context "for signed-in users" do
      before { sign_in(seller) }

      it "includes user metadata" do
        timestamp = (Time.current.to_f * 1000).to_i

        expect(controller.helper_widget_init_data).to eq(
          title: "Support",
          mailboxSlug: "gumroad",
          iconColor: "#FF90E8",
          enableGuide: true,
          timestamp: timestamp,
          email: seller.email,
          emailHash: controller.helper_widget_email_hmac(timestamp),
          customerMetadata: HelperUserInfoService.new(email: seller.email).metadata
        )
      end
    end

    context "for anonymous users" do
      it "does not include user metadata" do
        timestamp = (Time.current.to_f * 1000).to_i

        expect(controller.helper_widget_init_data).to eq(
          title: "Support",
          mailboxSlug: "gumroad",
          iconColor: "#FF90E8",
          enableGuide: true,
          timestamp: timestamp,
        )
      end
    end
  end
end
