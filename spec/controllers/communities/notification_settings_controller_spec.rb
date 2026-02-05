# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe Communities::NotificationSettingsController do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, community_chat_enabled: true, price_cents: 0) }
  let!(:community) { create(:community, resource: product, seller: seller) }

  before do
    Feature.activate_user(:communities, seller)
  end

  describe "PUT #update" do
    context "when feature flag is disabled" do
      let(:buyer) { create(:user) }
      let!(:purchase) { create(:free_purchase, seller: seller, purchaser: buyer, link: product) }

      before do
        Feature.deactivate_user(:communities, seller)
        sign_in(buyer)
      end

      it "redirects to dashboard with alert" do
        put :update, params: {
          community_id: community.external_id,
          settings: { recap_frequency: "weekly" }
        }

        expect(response).to redirect_to dashboard_path
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end
    end

    context "when community not found" do
      before do
        sign_in(seller)
      end

      it "returns 404" do
        put :update, params: {
          community_id: "nonexistent",
          settings: { recap_frequency: "weekly" }
        }

        expect(response).to have_http_status(:not_found)
      end
    end

    context "when logged in as a user with access" do
      let(:buyer) { create(:user) }
      let!(:purchase) { create(:free_purchase, seller: seller, purchaser: buyer, link: product) }

      before do
        sign_in(buyer)
      end

      it "creates notification settings" do
        expect do
          put :update, params: {
            community_id: community.external_id,
            settings: { recap_frequency: "weekly" }
          }
        end.to change(CommunityNotificationSetting, :count).by(1)

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        expect(response).to have_http_status(:see_other)

        settings = buyer.community_notification_settings.find_by(seller: seller)
        expect(settings.recap_frequency).to eq("weekly")
      end

      it "updates existing notification settings" do
        existing_settings = create(:community_notification_setting, user: buyer, seller: seller, recap_frequency: "daily")

        put :update, params: {
          community_id: community.external_id,
          settings: { recap_frequency: "weekly" }
        }

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        expect(response).to have_http_status(:see_other)
        expect(existing_settings.reload.recap_frequency).to eq("weekly")
      end

      it "allows setting recap_frequency to nil" do
        existing_settings = create(:community_notification_setting, user: buyer, seller: seller, recap_frequency: "weekly")

        put :update, params: {
          community_id: community.external_id,
          settings: { recap_frequency: nil }
        }

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        expect(response).to have_http_status(:see_other)
        expect(existing_settings.reload.recap_frequency).to be_nil
      end
    end

    context "when logged in as the seller" do
      before do
        sign_in(seller)
      end

      it "creates notification settings for seller" do
        expect do
          put :update, params: {
            community_id: community.external_id,
            settings: { recap_frequency: "daily" }
          }
        end.to change(CommunityNotificationSetting, :count).by(1)

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        expect(response).to have_http_status(:see_other)

        settings = seller.community_notification_settings.find_by(seller: seller)
        expect(settings.recap_frequency).to eq("daily")
      end

      it "updates existing notification settings" do
        settings = create(:community_notification_setting, seller: community.seller, user: seller, recap_frequency: "daily")

        put :update, params: {
          community_id: community.external_id,
          settings: { recap_frequency: "weekly" }
        }

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        expect(response).to have_http_status(:see_other)
        expect(settings.reload.recap_frequency).to eq("weekly")
      end
    end

    context "when logged in as a user without access" do
      let(:other_user) { create(:user) }

      before do
        sign_in(other_user)
      end

      it "redirects unauthorized users" do
        put :update, params: {
          community_id: community.external_id,
          settings: { recap_frequency: "weekly" }
        }

        expect(response).to have_http_status(:redirect)
      end
    end
  end
end
