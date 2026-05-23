# frozen_string_literal: true

require "test_helper"
require "shared_examples/admin_base_controller_concern"

class AdminLinksControllerTest < ActionController::TestCase
  self.described_class = Admin::LinksController
  tests Admin::LinksController



  context_ Admin::LinksController, type: :controller, inertia: true do
    render_views

    it_behaves_like "inherits from Admin::BaseController"

    let(:admin_user) { create(:admin_user) }
    let(:product) { create(:product) }

    before do
      sign_in admin_user
      @request.env["HTTP_REFERER"] = "where_i_came_from"
    end

  context_ "GET show" do
  test "redirects numeric ID to external_id" do
        get :show, params: { external_id: product.id }

        expect(response).to redirect_to(admin_product_path(product.external_id))
      end

  test "renders the product page if looked up via external_id" do
        get :show, params: { external_id: product.external_id }

        expect(response).to be_successful
        expect(inertia.component).to eq("Admin/Products/Show")
        expect(inertia.props[:title]).to eq(product.name)
        expect(inertia.props[:product]).to eq(Admin::ProductPresenter::Card.new(product:, pundit_user: SellerContext.new(user: admin_user, seller: product.user)).props)
        expect(inertia.props[:user]).to eq(Admin::UserPresenter::Card.new(user: product.user, pundit_user: SellerContext.new(user: admin_user, seller: product.user)).props)
      end

  context_ "multiple matches by permalink" do
  context_ "when multiple products matched by permalink" do
  test "lists all matches" do
            product_1 = create(:product, unique_permalink: "a", custom_permalink: "match")
            product_2 = create(:product, unique_permalink: "b", custom_permalink: "match")
            create(:product, unique_permalink: "c", custom_permalink: "should-not-match")

            get :show, params: { external_id: product_1.custom_permalink }

            expect(response).to be_successful
            expect(inertia.component).to eq("Admin/Products/MultipleMatches")
            expect(inertia.props[:product_matches]).to contain_exactly(hash_including(external_id: product_1.external_id), hash_including(external_id: product_2.external_id))
          end
        end

  context_ "when only one product matched by permalink" do
  test "renders the product page" do
            product = create(:product, unique_permalink: "a", custom_permalink: "match")

            get :show, params: { external_id: product.custom_permalink }

            expect(response).to be_successful
            expect(inertia.component).to eq("Admin/Products/Show")
            expect(inertia.props[:title]).to eq(product.name)
            expect(inertia.props[:product]).to eq(Admin::ProductPresenter::Card.new(product:, pundit_user: SellerContext.new(user: admin_user, seller: product.user)).props)
            expect(inertia.props[:user]).to eq(Admin::UserPresenter::Card.new(user: product.user, pundit_user: SellerContext.new(user: admin_user, seller: product.user)).props)
          end
        end

  context_ "when no products matched by permalink" do
  test "raises a 404" do
            expect do
              get :show, params: { external_id: "match" }
            end.to raise_error(ActionController::RoutingError, "Not Found")
          end
        end
      end
    end

  context_ "DELETE destroy" do
  test "deletes the product" do
        delete :destroy, params: { external_id: product.external_id }

        expect(response).to be_successful
        expect(product.reload.deleted_at).to be_present
      end

  test "raises a 404 if the product is not found" do
        expect do
          delete :destroy, params: { external_id: "invalid-id" }
        end.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end

  context_ "POST restore" do
      let(:product) { create(:product, deleted_at: 1.day.ago) }

  test "restores the product" do
        post :restore, params: { external_id: product.external_id }

        expect(response).to be_successful
        expect(product.reload.deleted_at).to be_nil
      end

  test "raises a 404 if the product is not found" do
        expect do
          post :restore, params: { external_id: "invalid-id" }
        end.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end

  context_ "POST publish" do
      let(:product) { create(:product, purchase_disabled_at: Time.current) }

  test "publishes the product" do
        post :publish, params: { external_id: product.external_id }

        expect(response).to be_successful
        expect(product.reload.purchase_disabled_at).to be_nil
      end

  test "raises a 404 if the product is not found" do
        expect do
          post :publish, params: { external_id: "invalid-id" }
        end.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end

  context_ "DELETE unpublish" do
      let(:product) { create(:product, purchase_disabled_at: nil) }

  test "unpublishes the product" do
        delete :unpublish, params: { external_id: product.external_id }

        expect(response).to be_successful
        expect(product.reload.purchase_disabled_at).to be_present
      end

  test "raises a 404 if the product is not found" do
        expect do
          delete :unpublish, params: { external_id: "invalid-id" }
        end.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end

  context_ "GET join_discord" do
      let(:integration) { create(:discord_integration) }
      let(:product) { create(:product, active_integrations: [integration]) }

  test "renders error when Discord returns a non-JSON response" do
        WebMock.stub_request(:post, DISCORD_OAUTH_TOKEN_URL).
          to_return(status: 200, body: "<html>502 Bad Gateway</html>", headers: { content_type: "text/html" })

        get :join_discord, params: { external_id: product.external_id, code: "test_code" }

        expect(response.body).to eq("Failed to get access token from Discord, try re-authorizing.")
      end
    end

  context_ "POST is_adult" do
  test "marks the product as adult" do
        post :is_adult, params: { external_id: product.external_id, is_adult: true }

        expect(response).to be_successful
        expect(product.reload.is_adult).to be(true)

        post :is_adult, params: { external_id: product.external_id, is_adult: false }

        expect(response).to be_successful
        expect(product.reload.is_adult).to be(false)
      end

  test "raises a 404 if the product is not found" do
        expect do
          post :is_adult, params: { external_id: "invalid-id", is_adult: true }
        end.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end

  context_ "POST set_content_moderation_disabled" do
  test "toggles content_moderation_disabled on the product" do
        post :set_content_moderation_disabled, params: { external_id: product.external_id, disabled: "true" }

        expect(response).to be_successful
        expect(product.reload.content_moderation_disabled?).to be(true)

        post :set_content_moderation_disabled, params: { external_id: product.external_id, disabled: "false" }

        expect(response).to be_successful
        expect(product.reload.content_moderation_disabled?).to be(false)
      end

  test "raises a 404 if the product is not found" do
        expect do
          post :set_content_moderation_disabled, params: { external_id: "invalid-id", disabled: "true" }
        end.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end
  end
end
