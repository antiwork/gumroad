# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe CommunitiesController, inertia: true do
  let(:seller) { create(:user) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }
  let(:product) { create(:product, user: seller, community_chat_enabled: true) }
  let!(:community) { create(:community, seller:, resource: product) }

  include_context "with user signed in as admin for seller"

  before do
    Feature.activate_user(:communities, seller)
  end

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { Community }
    end

    context "when seller is logged in" do
      before do
        sign_in seller
      end

      it "redirects to the first community" do
        get :index
        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
      end

      context "when seller has no communities" do
        before do
          community.destroy!
        end

        it "returns unauthorized response" do
          get :index
          expect(response).to redirect_to dashboard_path
          expect(flash[:alert]).to eq("You are not allowed to perform this action.")
        end
      end

      it "returns unauthorized response if the :communities feature flag is disabled" do
        Feature.deactivate_user(:communities, seller)

        get :index

        expect(response).to redirect_to dashboard_path
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end
    end
  end

  describe "GET #show" do
    it_behaves_like "authorize called for action", :get, :show do
      let(:record) { community }
      let(:request_params) { { seller_id: seller.external_id, community_id: community.external_id } }
    end

    context "when seller has an active community" do
      before do
        sign_in seller
      end

      it "renders the community page" do
        get :show, params: { seller_id: seller.external_id, community_id: community.external_id }
        expect(response).to be_successful
      end

      it "passes selected_community_id to props" do
        get :show, params: { seller_id: seller.external_id, community_id: community.external_id }
        expect(inertia.props[:selected_community_id]).to eq(community.external_id)
      end

      it "returns not found for invalid community" do
        expect {
          get :show, params: { seller_id: seller.external_id, community_id: "invalid" }
        }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "returns unauthorized if :communities feature flag is disabled" do
        Feature.deactivate_user(:communities, seller)
        get :show, params: { seller_id: seller.external_id, community_id: community.external_id }
        expect(response).to redirect_to dashboard_path
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end
    end

    context "when user cannot access the community" do
      let(:other_seller) { create(:user) }

      before do
        sign_in other_seller
      end

      it "returns unauthorized" do
        get :show, params: { seller_id: seller.external_id, community_id: community.external_id }
        expect(response).to redirect_to(dashboard_path)
      end
    end
  end

  describe "PUT #update_notification_settings" do
    before do
      sign_in seller
    end

    it "creates notification settings when they don't exist" do
      expect {
        put :update_notification_settings, params: {
          seller_id: seller.external_id,
          community_id: community.external_id,
          recap_frequency: "daily"
        }
      }.to change { CommunityNotificationSetting.count }.by(1)

      settings = seller.community_notification_settings.find_by(seller: seller)
      expect(settings.recap_frequency).to eq("daily")
      expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
      expect(flash[:notice]).to eq("Changes saved!")
    end

    it "updates existing notification settings" do
      existing_settings = create(:community_notification_setting, user: seller, seller: seller, recap_frequency: "daily")

      put :update_notification_settings, params: {
        seller_id: seller.external_id,
        community_id: community.external_id,
        recap_frequency: "weekly"
      }

      existing_settings.reload
      expect(existing_settings.recap_frequency).to eq("weekly")
      expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
    end

    it "allows setting recap_frequency to nil" do
      existing_settings = create(:community_notification_setting, user: seller, seller: seller, recap_frequency: "weekly")

      put :update_notification_settings, params: {
        seller_id: seller.external_id,
        community_id: community.external_id,
        recap_frequency: nil
      }

      existing_settings.reload
      expect(existing_settings.recap_frequency).to be_nil
    end

    context "when user cannot access the community" do
      let(:other_user) { create(:user) }

      before do
        sign_in other_user
        Feature.activate_user(:communities, other_user)
      end

      it "returns unauthorized" do
        put :update_notification_settings, params: {
          seller_id: seller.external_id,
          community_id: community.external_id,
          recap_frequency: "daily"
        }

        expect(response).to redirect_to(dashboard_path)
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end
    end

    it "returns unauthorized if :communities feature flag is disabled" do
      Feature.deactivate_user(:communities, seller)
      put :update_notification_settings, params: {
        seller_id: seller.external_id,
        community_id: community.external_id,
        recap_frequency: "daily"
      }
      expect(response).to redirect_to dashboard_path
      expect(flash[:alert]).to eq("You are not allowed to perform this action.")
    end
  end
end
