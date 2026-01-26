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
        expect(inertia.component).to eq("Communities/Index")
        expect(inertia.props).to include(
          has_products: be_in([true, false]),
          communities: be_an(Array),
          notification_settings: be_a(Hash)
        )
      end

      it "includes communities presenter data" do
        get :index

        presenter_props = CommunitiesPresenter.new(current_user: seller).props

        expect(inertia.props[:has_products]).to eq(presenter_props[:has_products])
        expect(inertia.props[:communities]).to eq(presenter_props[:communities])
        expect(inertia.props[:notification_settings]).to eq(presenter_props[:notification_settings])
      end

      it "sets the page title" do
        get :index

        expect(assigns(:title)).to eq("Communities")
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
      let(:record) { community }
      let(:request_params) { { id: community.external_id } }
    end

    context "when seller is logged in" do
      before do
        sign_in seller
      end

      it "renders with selectedCommunityId" do
        get :show, params: { id: community.external_id }

        expect(response).to be_successful
        expect(inertia.component).to eq("Communities/Index")
        expect(inertia.props).to include(
          has_products: be_in([true, false]),
          communities: be_an(Array),
          notification_settings: be_a(Hash),
          selectedCommunityId: community.external_id
        )
      end

      it "includes the selected community ID in props" do
        get :show, params: { id: community.external_id }

        expect(inertia.props[:selectedCommunityId]).to eq(community.external_id)
      end

      it "returns 404 when community does not exist" do
        get :show, params: { id: "invalid_id" }

        expect(response).to have_http_status(:not_found)
      end

      it "returns unauthorized response if the :communities feature flag is disabled" do
        Feature.deactivate_user(:communities, seller)

        get :show, params: { id: community.external_id }

        expect(response).to redirect_to dashboard_path
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end

      context "when user does not have access to the community" do
        let(:other_seller) { create(:user) }
        let(:other_product) { create(:product, user: other_seller, community_chat_enabled: true) }
        let(:other_community) { create(:community, seller: other_seller, resource: other_product) }

        before do
          Feature.activate_user(:communities, other_seller)
        end

        it "returns unauthorized response" do
          get :show, params: { id: other_community.external_id }

          expect(response).to redirect_to dashboard_path
          expect(flash[:alert]).to eq("You are not allowed to perform this action.")
        end
      end
    end
  end
end
