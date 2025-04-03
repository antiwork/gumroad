# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Api::Internal::Communities::NotificationSettingsController do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, community_chat_enabled: true) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }
  let!(:community) { create(:community, resource: product, seller:) }

  include_context "with user signed in as admin for seller"

  before do
    Feature.activate_user(:communities, seller)
  end

  describe "PUT update" do
    it_behaves_like "authorize called for action", :put, :update do
      let(:record) { community }
      let(:policy_method) { :show? }
      let(:request_params) { { community_id: community.external_id } }
    end

    it "returns unauthorized response if the :communities feature flag is disabled" do
      Feature.deactivate_user(:communities, seller)

      put :update, params: { community_id: community.external_id }

      expect(response).to redirect_to dashboard_path
      expect(flash[:alert]).to eq("Your current role as Admin cannot perform this action.")
    end

    it "returns 404 when community is not found" do
      put :update, params: { community_id: "nonexistent" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ "success" => false, "error" => "Not found" })
    end

    context "when seller is logged in" do
      before do
        sign_in seller
      end

      it "creates notification settings when they don't exist" do
        expect do
          put :update, params: {
            community_id: community.external_id,
            settings: { recap_frequency: "daily" }
          }
        end.to change { CommunityNotificationSetting.count }.by(1)

        expect(response).to be_successful
        expect(response.parsed_body["settings"]).to include(
          "recap_frequency" => "daily"
        )
        notification_setting = CommunityNotificationSetting.last
        expect(notification_setting.seller).to eq(community.seller)
        expect(notification_setting.user).to eq(seller)
        expect(notification_setting.recap_frequency).to eq("daily")
      end

      it "updates existing notification settings" do
        settings = create(:community_notification_setting, seller: community.seller, user: seller)
        expect do
          put :update, params: {
            community_id: community.external_id,
            settings: { recap_frequency: "weekly" }
          }
        end.to_not change { CommunityNotificationSetting.count }

        expect(response).to be_successful
        expect(response.parsed_body["settings"]).to include(
          "recap_frequency" => "weekly"
        )
        expect(settings.reload.recap_frequency).to eq("weekly")
      end
    end

    context "when buyer is logged in" do
      let(:buyer) { create(:user) }
      let!(:purchase) { create(:purchase, purchaser: buyer, link: product) }

      before do
        sign_in buyer
      end

      it "creates notification settings when they don't exist" do
        expect do
          put :update, params: {
            community_id: community.external_id,
            settings: { recap_frequency: "daily" }
          }
        end.to change { CommunityNotificationSetting.count }.by(1)

        expect(response).to be_successful
        expect(response.parsed_body["settings"]).to include(
          "recap_frequency" => "daily"
        )
        notification_setting = CommunityNotificationSetting.last
        expect(notification_setting.seller).to eq(community.seller)
        expect(notification_setting.user).to eq(buyer)
        expect(notification_setting.recap_frequency).to eq("daily")
      end

      it "updates existing notification settings" do
        settings = create(:community_notification_setting, seller: community.seller, user: buyer)
        expect do
          put :update, params: {
            community_id: community.external_id,
            settings: { recap_frequency: "weekly" }
          }
        end.to_not change { CommunityNotificationSetting.count }

        expect(response).to be_successful
        expect(response.parsed_body["settings"]).to include(
          "recap_frequency" => "weekly"
        )
        expect(settings.reload.recap_frequency).to eq("weekly")
      end
    end
  end
end
