# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe CommunitiesController, inertia: true do
  render_views
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, community_chat_enabled: true) }
  let!(:community) { create(:community, seller:, resource: product) }

  before do
    Feature.activate_user(:communities, seller)
  end

  describe "GET index" do
    context "when feature flag is disabled" do
      before do
        Feature.deactivate_user(:communities, seller)
        sign_in seller
      end

      it "redirects to dashboard with alert" do
        get :index

        expect(response).to redirect_to dashboard_path
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end
    end

    context "when logged in as seller" do
      before do
        sign_in seller
      end

      it "redirects to the first community" do
        get :index
        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
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
    context "when feature flag is disabled" do
      before do
        Feature.deactivate_user(:communities, seller)
        sign_in seller
      end

      it "redirects to dashboard with alert" do
        get :show, params: { seller_id: seller.external_id, community_id: community.external_id }

        expect(response).to redirect_to dashboard_path
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end
    end

    context "when community not found" do
      before do
        sign_in seller
      end

      it "returns 404" do
        expect do
          get :show, params: { seller_id: seller.external_id, community_id: "nonexistent" }
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "when logged in as seller" do
      before do
        sign_in seller
      end

      it "returns success" do
        get :show, params: { seller_id: seller.external_id, community_id: community.external_id }

        expect(response).to be_successful
        expect(inertia).to render_component("Communities/Index")
      end

      it "loads community data" do
        get :show, params: { seller_id: seller.external_id, community_id: community.external_id }

        expect(inertia).to render_component("Communities/Index")
        expect(inertia.props[:selected_community_id]).to eq(community.external_id)
      end
    end

    context "when logged in as a buyer with purchase" do
      let(:buyer) { create(:user) }
      let!(:purchase) { create(:free_purchase, seller: seller, purchaser: buyer, link: product) }

      before do
        sign_in buyer
      end

      it "returns success" do
        get :show, params: { seller_id: seller.external_id, community_id: community.external_id }

        expect(response).to be_successful
        expect(inertia).to render_component("Communities/Index")
      end
    end

    context "when logged in as a buyer without purchase" do
      let(:other_user) { create(:user) }

      before do
        sign_in other_user
      end

      it "redirects with unauthorized alert" do
        get :show, params: { seller_id: seller.external_id, community_id: community.external_id }

        expect(response).to have_http_status(:redirect)
        expect(flash[:alert]).to be_present
      end
    end
  end
end
