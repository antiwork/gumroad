# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe Settings::ThirdPartyAnalyticsController, type: :controller, inertia: true do
  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  it_behaves_like "authorize called for controller", Settings::ThirdPartyAnalytics::UserPolicy do
    let(:record) { seller }
  end

  describe "GET show" do
    it "returns http success and renders Inertia component" do
      get :show
      expect(response).to be_successful
      expect(inertia.component).to eq("Settings/ThirdPartyAnalytics/Show")
      settings_presenter = SettingsPresenter.new(pundit_user: controller.pundit_user)
      expected_props = {
        third_party_analytics: settings_presenter.third_party_analytics_props,
        meta_conversions: nil,
        products: seller.links.alive.map { |product| { permalink: product.unique_permalink, name: product.name } },
      }
      # Compare only the expected props from inertia.props (ignore shared props)
      actual_props = inertia.props.slice(*expected_props.keys)
      expect(actual_props).to eq(expected_props)
    end

    it "never includes the saved Conversions API access token" do
      Feature.activate_user(:meta_conversions_api, seller)
      seller.create_meta_conversions_setting!(access_token: "secret-token")

      get :show

      expect(inertia.props[:meta_conversions]).to eq(token_saved: true, token_rejected_at: nil)
      expect(response.body).not_to include("secret-token")
    end
  end

  describe "PUT update" do
    google_analytics_id = "G-1234567"
    facebook_pixel_id = "123456789"
    tiktok_pixel_id = "CFH83AJC77UUUGLE2TJG"
    facebook_meta_tag = '<meta name="facebook-domain-verification" content="dkd8382hfdjs" />'

    context "when all of the fields are valid" do
      it "returns a successful response" do
        put :update, params: {
          user: {
            disable_third_party_analytics: false,
            google_analytics_id:,
            facebook_pixel_id:,
            tiktok_pixel_id:,
            skip_free_sale_analytics: true,
            enable_verify_domain_third_party_services: true,
            facebook_meta_tag:,
          }
        }
        expect(response).to redirect_to(settings_third_party_analytics_path)
        expect(response).to have_http_status :see_other
        expect(flash[:notice]).to eq("Changes saved!")
        seller.reload
        expect(seller.disable_third_party_analytics).to eq(false)
        expect(seller.google_analytics_id).to eq(google_analytics_id)
        expect(seller.facebook_pixel_id).to eq(facebook_pixel_id)
        expect(seller.tiktok_pixel_id).to eq(tiktok_pixel_id)
        expect(seller.skip_free_sale_analytics).to eq(true)
        expect(seller.enable_verify_domain_third_party_services).to eq(true)
        expect(seller.facebook_meta_tag).to eq(facebook_meta_tag)
      end
    end

    context "when a field is invalid" do
      it "returns an error response and doesn't persist changes" do
        put :update, params: {
          user: {
            disable_third_party_analytics: false,
            google_analytics_id: "bad",
            facebook_pixel_id:,
            tiktok_pixel_id:,
            skip_free_sale_analytics: true,
            enable_verify_domain_third_party_services: true,
            facebook_meta_tag:,
          }
        }

        expect(response).to redirect_to(settings_third_party_analytics_path)
        expect(response).to have_http_status :found
        expect(flash[:alert]).to eq("Please enter a valid Google Analytics ID")

        seller.reload
        expect(seller.disable_third_party_analytics).to eq(false)
        expect(seller.google_analytics_id).to be_nil
        expect(seller.facebook_pixel_id).to be_nil
        expect(seller.tiktok_pixel_id).to be_nil
        expect(seller.skip_free_sale_analytics).to eq(false)
        expect(seller.enable_verify_domain_third_party_services).to eq(false)
        expect(seller.facebook_meta_tag).to be_nil
      end

      it "returns an error response for invalid TikTok Pixel ID" do
        put :update, params: {
          user: {
            tiktok_pixel_id: "invalid-pixel!",
          }
        }

        expect(response).to redirect_to(settings_third_party_analytics_path)
        expect(response).to have_http_status :found
        expect(flash[:alert]).to eq("Please enter a valid TikTok Pixel ID")

        seller.reload
        expect(seller.tiktok_pixel_id).to be_nil
      end
    end

    context "when the Facebook Pixel ID has surrounding whitespace" do
      it "strips it before saving" do
        put :update, params: { user: { facebook_pixel_id: "  1258008389687474 " } }

        expect(flash[:notice]).to eq("Changes saved!")
        expect(seller.reload.facebook_pixel_id).to eq("1258008389687474")
      end
    end

    context "when the Facebook Pixel ID is not numeric" do
      it "returns an error and doesn't persist it" do
        put :update, params: { user: { facebook_pixel_id: "pixel-123" } }

        expect(flash[:alert]).to eq("Please enter a valid Facebook Pixel ID")
        expect(seller.reload.facebook_pixel_id).to be_nil
      end
    end

    describe "Conversions API access token" do
      context "when the feature is on for the seller" do
        before { Feature.activate_user(:meta_conversions_api, seller) }

        it "saves a token" do
          put :update, params: { user: { meta_conversions_access_token: " token-1 " } }

          expect(flash[:notice]).to eq("Changes saved!")
          expect(seller.reload.meta_conversions_setting.access_token).to eq("token-1")
        end

        it "replaces a token and clears the rejection" do
          seller.create_meta_conversions_setting!(access_token: "token-1", token_rejected_at: Time.current)

          put :update, params: { user: { meta_conversions_access_token: "token-2" } }

          setting = seller.reload.meta_conversions_setting
          expect(setting.access_token).to eq("token-2")
          expect(setting.token_rejected_at).to be_nil
        end

        it "keeps the token when the field is blank" do
          rejected_at = 1.day.ago.change(usec: 0)
          seller.create_meta_conversions_setting!(access_token: "token-1", token_rejected_at: rejected_at)

          put :update, params: { user: { meta_conversions_access_token: "", facebook_pixel_id: "123456789" } }

          setting = seller.reload.meta_conversions_setting
          expect(setting.access_token).to eq("token-1")
          expect(setting.token_rejected_at).to eq(rejected_at)
        end

        it "removes the token" do
          seller.create_meta_conversions_setting!(access_token: "token-1")

          put :update, params: { user: { remove_meta_conversions_access_token: true } }

          expect(seller.reload.meta_conversions_setting).to be_nil
        end

        it "removes the token when a replacement token is sent with the removal flag" do
          seller.create_meta_conversions_setting!(access_token: "token-1")

          put :update, params: {
            user: { meta_conversions_access_token: "token-2", remove_meta_conversions_access_token: true }
          }

          expect(seller.reload.meta_conversions_setting).to be_nil
        end

        it "does not save a token when the other settings are invalid" do
          put :update, params: { user: { google_analytics_id: "bad", meta_conversions_access_token: "token-1" } }

          expect(flash[:alert]).to eq("Please enter a valid Google Analytics ID")
          expect(seller.reload.meta_conversions_setting).to be_nil
        end
      end

      context "when the feature is off for the seller" do
        it "does not save a token" do
          put :update, params: { user: { meta_conversions_access_token: "token-1" } }

          expect(flash[:notice]).to eq("Changes saved!")
          expect(seller.reload.meta_conversions_setting).to be_nil
        end

        it "does not remove a token" do
          seller.create_meta_conversions_setting!(access_token: "token-1")

          put :update, params: { user: { remove_meta_conversions_access_token: true } }

          expect(seller.reload.meta_conversions_setting.access_token).to eq("token-1")
        end
      end
    end

    context "when updating throws an error" do
      it "returns an error response" do
        allow_any_instance_of(User).to receive(:update).and_raise(StandardError)
        put :update, params: {}

        expect(response).to redirect_to(settings_third_party_analytics_path)
        expect(response).to have_http_status :found
        expect(flash[:alert]).to eq("Something broke. We're looking into what happened. Sorry about this!")
      end
    end
  end
end
