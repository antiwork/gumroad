# frozen_string_literal: true

require "test_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

class CommunitiesControllerTest < ActionController::TestCase
  self.described_class = CommunitiesController
  tests CommunitiesController



  context_ CommunitiesController, inertia: true do
    render_views

    let(:seller) { create(:user) }
    let(:pundit_user) { SellerContext.new(user: seller, seller:) }
    let(:product) { create(:product, user: seller, community_chat_enabled: true) }
    let!(:community) { create(:community, seller:, resource: product) }

    include_context "with user signed in as admin for seller"

    before do
      Feature.activate_user(:communities, seller)
    end

  context_ "GET index" do
      it_behaves_like "authorize called for action", :get, :index do
        let(:record) { Community }
      end

  context_ "when seller is logged in" do
        before do
          sign_in seller
        end

  test "redirects to the first community when communities exist" do
          get :index

          expect(response).to redirect_to(community_path(community.seller.external_id, community.external_id))
        end

  context_ "when no communities exist" do
          before do
            community.destroy!
          end

  test "redirects to dashboard when user has no accessible communities" do
            get :index

            expect(response).to redirect_to(dashboard_path)
            expect(flash[:alert]).to eq("You are not allowed to perform this action.")
          end
        end

  test "returns unauthorized response if the :communities feature flag is disabled" do
          Feature.deactivate_user(:communities, seller)

          get :index

          expect(response).to redirect_to dashboard_path
          expect(flash[:alert]).to eq("You are not allowed to perform this action.")
        end
      end
    end

  context_ "GET show" do
      it_behaves_like "authorize called for action", :get, :show do
        let(:request_params) { { seller_id: seller.external_id, community_id: community.external_id } }
        let(:record) { community }
      end

  context_ "when seller is logged in" do
        before do
          sign_in seller
        end

  test "renders the Inertia component with correct props" do
          get :show, params: { seller_id: seller.external_id, community_id: community.external_id }

          expect(response).to be_successful
          expect(controller.send(:page_title)).to eq("Communities")
          expect_inertia.to render_component("Communities/Index")
          expect_inertia.to include_props(has_products: true)
          expect_inertia.to include_props(selectedCommunityId: community.external_id)
        end

  test "includes selectedCommunityId in props" do
          get :show, params: { seller_id: seller.external_id, community_id: community.external_id }

          expect(inertia.props[:selectedCommunityId]).to eq(community.external_id)
        end

  test "includes messages prop with scroll metadata" do
          message = create(:community_chat_message, community:, user: seller)

          get :show, params: { seller_id: seller.external_id, community_id: community.external_id }

          expect(inertia.props[:messages]).to be_an(Array)
          expect(inertia.props[:messages].length).to eq(1)
          expect(inertia.props[:messages].first[:id]).to eq(message.external_id)
        end

  test "returns paginated messages with cursor param" do
          old_message = create(:community_chat_message, community:, user: seller, created_at: 30.minutes.ago)
          create(:community_chat_message, community:, user: seller, created_at: 10.minutes.ago)

          get :show, params: {
            seller_id: seller.external_id,
            community_id: community.external_id,
            cursor: 20.minutes.ago.iso8601
          }

          expect(inertia.props[:messages]).to be_an(Array)
          expect(inertia.props[:messages].map { |m| m[:id] }).to include(old_message.external_id)
        end

  test "returns older messages with X-Inertia-Infinite-Scroll-Merge-Intent: prepend header" do
          old_message = create(:community_chat_message, community:, user: seller, created_at: 30.minutes.ago)
          new_message = create(:community_chat_message, community:, user: seller, created_at: 10.minutes.ago)

          request.headers["X-Inertia-Infinite-Scroll-Merge-Intent"] = "prepend"
          get :show, params: {
            seller_id: seller.external_id,
            community_id: community.external_id,
            cursor: 20.minutes.ago.iso8601
          }

          expect(inertia.props[:messages]).to be_an(Array)
          expect(inertia.props[:messages].map { |m| m[:id] }).to include(old_message.external_id)
          expect(inertia.props[:messages].map { |m| m[:id] }).not_to include(new_message.external_id)
        end

  test "raises error when community does not exist" do
          expect do
            get :show, params: { seller_id: seller.external_id, community_id: "non-existent" }
          end.to raise_error(ActiveRecord::RecordNotFound)
        end

  test "raises error when seller does not exist" do
          expect do
            get :show, params: { seller_id: "non-existent", community_id: community.external_id }
          end.to raise_error(ActiveRecord::RecordNotFound)
        end

  test "raises error when community does not belong to seller" do
          other_seller = create(:user)
          other_product = create(:product, user: other_seller, community_chat_enabled: true)
          other_community = create(:community, seller: other_seller, resource: other_product)

          expect do
            get :show, params: { seller_id: seller.external_id, community_id: other_community.external_id }
          end.to raise_error(ActiveRecord::RecordNotFound)
        end

  test "returns unauthorized response if the :communities feature flag is disabled" do
          Feature.deactivate_user(:communities, seller)

          get :show, params: { seller_id: seller.external_id, community_id: community.external_id }

          expect(response).to redirect_to dashboard_path
          expect(flash[:alert]).to eq("You are not allowed to perform this action.")
        end
      end

  context_ "when buyer is logged in" do
        let(:buyer) { create(:user) }
        let!(:purchase) { create(:purchase, seller:, purchaser: buyer, link: product) }

        before do
          Feature.activate_user(:communities, buyer)
          sign_in buyer
        end

  test "renders the Inertia component for communities they have access to" do
          get :show, params: { seller_id: seller.external_id, community_id: community.external_id }

          expect(response).to be_successful
          expect_inertia.to render_component("Communities/Index")
          expect_inertia.to include_props(selectedCommunityId: community.external_id)
        end

  test "returns unauthorized response for communities they don't have access to" do
          other_seller = create(:user)
          Feature.activate_user(:communities, other_seller)
          other_product = create(:product, user: other_seller, community_chat_enabled: true)
          other_community = create(:community, seller: other_seller, resource: other_product)

          get :show, params: { seller_id: other_seller.external_id, community_id: other_community.external_id }

          expect(response).to redirect_to(dashboard_path)
          expect(flash[:alert]).to eq("You are not allowed to perform this action.")
        end
      end

  context_ "when community is deleted" do
        before do
          sign_in seller
          community.mark_deleted!
        end

  test "raises error when trying to access deleted community" do
          expect do
            get :show, params: { seller_id: seller.external_id, community_id: community.external_id }
          end.to raise_error(ActiveRecord::RecordNotFound)
        end
      end
    end
  end
end
