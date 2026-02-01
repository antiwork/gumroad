# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe CommunitiesController, inertia: true do
  render_views

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

      it "renders the Inertia component with correct props" do
        get :index

        expect(response).to be_successful
        expect(controller.send(:page_title)).to eq("Communities")
        expect_inertia.to render_component("Communities/Index")
        expect_inertia.to include_props(has_products: true)
      end

      it "includes communities in props" do
        get :index

        expect(inertia.props[:communities]).to be_an(Array)
        expect(inertia.props[:communities].length).to eq(1)
        expect(inertia.props[:communities].first[:id]).to eq(community.external_id)
      end

      it "does not include selectedCommunityId in props for index action" do
        get :index

        expect(inertia.props).not_to have_key(:selectedCommunityId)
      end

      it "returns unauthorized response if the :communities feature flag is disabled" do
        Feature.deactivate_user(:communities, seller)

        get :index

        expect(response).to redirect_to dashboard_path
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end
    end
  end

  describe "GET show" do
    it_behaves_like "authorize called for action", :get, :show do
      let(:request_params) { { seller_id: seller.external_id, community_id: community.external_id } }
      let(:record) { community }
    end

    context "when seller is logged in" do
      before do
        sign_in seller
      end

      it "renders the Inertia component with correct props" do
        get :show, params: { seller_id: seller.external_id, community_id: community.external_id }

        expect(response).to be_successful
        expect(controller.send(:page_title)).to eq("Communities")
        expect_inertia.to render_component("Communities/Index")
        expect_inertia.to include_props(has_products: true)
        expect_inertia.to include_props(selectedCommunityId: community.external_id)
      end

      it "includes selectedCommunityId in props" do
        get :show, params: { seller_id: seller.external_id, community_id: community.external_id }

        expect(inertia.props[:selectedCommunityId]).to eq(community.external_id)
      end

      it "raises error when community does not exist" do
        expect {
          get :show, params: { seller_id: seller.external_id, community_id: "non-existent" }
        }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "raises error when seller does not exist" do
        expect {
          get :show, params: { seller_id: "non-existent", community_id: community.external_id }
        }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "raises error when community does not belong to seller" do
        other_seller = create(:user)
        other_product = create(:product, user: other_seller, community_chat_enabled: true)
        other_community = create(:community, seller: other_seller, resource: other_product)

        expect {
          get :show, params: { seller_id: seller.external_id, community_id: other_community.external_id }
        }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "returns unauthorized response if the :communities feature flag is disabled" do
        Feature.deactivate_user(:communities, seller)

        get :show, params: { seller_id: seller.external_id, community_id: community.external_id }

        expect(response).to redirect_to dashboard_path
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end
    end

    context "when buyer is logged in" do
      let(:buyer) { create(:user) }
      let!(:purchase) { create(:purchase, seller:, purchaser: buyer, link: product, price_cents: 0) }

      before do
        Feature.activate_user(:communities, buyer)
        sign_in buyer
      end

      it "renders the Inertia component for communities they have access to" do
        get :show, params: { seller_id: seller.external_id, community_id: community.external_id }

        expect(response).to be_successful
        expect_inertia.to render_component("Communities/Index")
        expect_inertia.to include_props(selectedCommunityId: community.external_id)
      end

      it "returns unauthorized response for communities they don't have access to" do
        other_seller = create(:user)
        Feature.activate_user(:communities, other_seller)
        other_product = create(:product, user: other_seller, community_chat_enabled: true)
        other_community = create(:community, seller: other_seller, resource: other_product)

        get :show, params: { seller_id: other_seller.external_id, community_id: other_community.external_id }

        expect(response).to redirect_to(dashboard_path)
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end
    end

    context "when community is deleted" do
      before do
        sign_in seller
        community.mark_deleted!
      end

      it "raises error when trying to access deleted community" do
        expect {
          get :show, params: { seller_id: seller.external_id, community_id: community.external_id }
        }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "PUT update_notification_settings" do
    it_behaves_like "authorize called for action", :put, :update_notification_settings do
      let(:record) { community }
      let(:policy_method) { :show? }
      let(:request_params) { { seller_id: seller.external_id, community_id: community.external_id } }
    end

    it "returns unauthorized response if the :communities feature flag is disabled" do
      Feature.deactivate_user(:communities, seller)

      put :update_notification_settings, params: { seller_id: seller.external_id, community_id: community.external_id }

      expect(response).to redirect_to dashboard_path
      expect(flash[:alert]).to eq("Your current role as Admin cannot perform this action.")
    end

    it "raises error when community is not found" do
      sign_in seller

      expect {
        put :update_notification_settings, params: { seller_id: seller.external_id, community_id: "nonexistent" }
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    context "when seller is logged in" do
      before do
        sign_in seller
      end

      it "creates notification settings when they don't exist" do
        expect do
          put :update_notification_settings, params: {
            seller_id: seller.external_id,
            community_id: community.external_id,
            recap_frequency: "daily"
          }
        end.to change { CommunityNotificationSetting.count }.by(1)

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        expect(flash[:notice]).to eq("Changes saved!")
        notification_setting = CommunityNotificationSetting.last
        expect(notification_setting.seller).to eq(community.seller)
        expect(notification_setting.user).to eq(seller)
        expect(notification_setting.recap_frequency).to eq("daily")
      end

      it "updates existing notification settings" do
        settings = create(:community_notification_setting, seller: community.seller, user: seller)
        expect do
          put :update_notification_settings, params: {
            seller_id: seller.external_id,
            community_id: community.external_id,
            recap_frequency: "weekly"
          }
        end.not_to change { CommunityNotificationSetting.count }

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        expect(flash[:notice]).to eq("Changes saved!")
        expect(settings.reload.recap_frequency).to eq("weekly")
      end
    end

    context "when buyer is logged in" do
      let(:buyer) { create(:user) }
      let!(:purchase) { create(:purchase, seller:, purchaser: buyer, link: product, price_cents: 0) }

      before do
        Feature.activate_user(:communities, buyer)
        sign_in buyer
      end

      it "creates notification settings when they don't exist" do
        expect do
          put :update_notification_settings, params: {
            seller_id: seller.external_id,
            community_id: community.external_id,
            recap_frequency: "daily"
          }
        end.to change { CommunityNotificationSetting.count }.by(1)

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        expect(flash[:notice]).to eq("Changes saved!")
        notification_setting = CommunityNotificationSetting.last
        expect(notification_setting.seller).to eq(community.seller)
        expect(notification_setting.user).to eq(buyer)
        expect(notification_setting.recap_frequency).to eq("daily")
      end

      it "updates existing notification settings" do
        settings = create(:community_notification_setting, seller: community.seller, user: buyer)
        expect do
          put :update_notification_settings, params: {
            seller_id: seller.external_id,
            community_id: community.external_id,
            recap_frequency: "weekly"
          }
        end.not_to change { CommunityNotificationSetting.count }

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        expect(flash[:notice]).to eq("Changes saved!")
        expect(settings.reload.recap_frequency).to eq("weekly")
      end
    end
  end
end
