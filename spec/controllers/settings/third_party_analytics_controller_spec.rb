# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Settings::ThirdPartyAnalyticsController do
  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  it_behaves_like "authorize called for controller", Settings::ThirdPartyAnalytics::UserPolicy do
    let(:record) { seller }
  end

  describe "GET show" do
    it "returns http success and assigns correct instance variables" do
      get :show
      expect(response).to be_successful
      expect(assigns[:title]).to eq("Settings")

      settings_presenter = assigns[:settings_presenter]
      expect(settings_presenter.pundit_user).to eq(controller.pundit_user)
    end
  end

  describe "PUT update" do
    google_analytics_id = "G-1234567"
    facebook_pixel_id = "123456789"
    facebook_meta_tag = '<meta name="facebook-domain-verification" content="dkd8382hfdjs" />'

    context "when all of the fields are valid" do
      it "returns a successful response" do
        put :update, as: :json, params: {
          user: {
            disable_third_party_analytics: false,
            google_analytics_id:,
            facebook_pixel_id:,
            skip_free_sale_analytics: true,
            enable_verify_domain_third_party_services: true,
            facebook_meta_tag:,
          }
        }
        expect(response.parsed_body["success"]).to eq(true)
        seller.reload
        expect(seller.disable_third_party_analytics).to eq(false)
        expect(seller.google_analytics_id).to eq(google_analytics_id)
        expect(seller.facebook_pixel_id).to eq(facebook_pixel_id)
        expect(seller.skip_free_sale_analytics).to eq(true)
        expect(seller.enable_verify_domain_third_party_services).to eq(true)
        expect(seller.facebook_meta_tag).to eq(facebook_meta_tag)
      end
    end

    context "when a field is invalid" do
      it "returns an error response and doesn't persist changes" do
        put :update, as: :json, params: {
          user: {
            disable_third_party_analytics: false,
            google_analytics_id: "bad",
            facebook_pixel_id:,
            skip_free_sale_analytics: true,
            enable_verify_domain_third_party_services: true,
            facebook_meta_tag:,
          }
        }

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["error_message"]).to eq("Please enter a valid Google Analytics ID")

        seller.reload
        expect(seller.disable_third_party_analytics).to eq(false)
        expect(seller.google_analytics_id).to be_nil
        expect(seller.facebook_pixel_id).to be_nil
        expect(seller.skip_free_sale_analytics).to eq(false)
        expect(seller.enable_verify_domain_third_party_services).to eq(false)
        expect(seller.facebook_meta_tag).to be_nil
      end
    end

    context "when updating throws an error" do
      it "returns an error response" do
        allow_any_instance_of(User).to receive(:update).and_raise(StandardError)
        put :update, as: :json, params: {}

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["error_message"]).to eq("Something broke. We're looking into what happened. Sorry about this!")
      end
    end
  end
end
