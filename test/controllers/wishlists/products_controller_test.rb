# frozen_string_literal: true

require "test_helper"
require "shared_examples/authorize_called"

class WishlistsProductsControllerTest < ActionController::TestCase
  self.described_class = Wishlists::ProductsController
  tests Wishlists::ProductsController



  context_ Wishlists::ProductsController do
    let(:user) { create(:user) }
    let(:wishlist) { create(:wishlist, user: user) }

    before do
      sign_in(user)
    end

  context_ "POST create" do
      let(:product) { create(:product) }

      it_behaves_like "authorize called for action", :post, :create do
        let(:record) { wishlist }
        let(:request_params) { { wishlist_id: wishlist.external_id } }
      end

      it_behaves_like "authorize called for action", :post, :create do
        let(:record) { WishlistProduct }
        let(:request_params) { { wishlist_id: wishlist.external_id } }
      end

  test "adds a product to the wishlist" do
        expect do
          post :create, params: { wishlist_id: wishlist.external_id, wishlist_product: { product_id: product.external_id } }
        end.to change(wishlist.wishlist_products, :count).from(0).to(1)

        expect(wishlist.wishlist_products.first).to have_attributes(
          product:,
          quantity: 1,
          rent: false,
          recurrence: nil,
          variant: nil
        )
      end

  test "sets variant and recurrence" do
        product = create(:subscription_product_with_versions)

        expect do
          post :create, params: {
            wishlist_id: wishlist.external_id,
            wishlist_product: {
              product_id: product.external_id,
              recurrence: BasePrice::Recurrence::MONTHLY,
              option_id: product.options.first[:id]
            }
          }
        end.to change(WishlistProduct, :count).by(1)

        expect(wishlist.wishlist_products.sole).to have_attributes(
          product:,
          recurrence: BasePrice::Recurrence::MONTHLY,
          variant: product.alive_variants.first
        )
      end

  test "sets quantity and rent" do
        product = create(:product, quantity_enabled: true, purchase_type: :buy_and_rent, rental_price_cents: 100)

        expect do
          post :create, params: {
            wishlist_id: wishlist.external_id,
            wishlist_product: {
              product_id: product.external_id,
              quantity: 2,
              rent: true
            }
          }
        end.to change(WishlistProduct, :count).by(1)

        expect(wishlist.wishlist_products.sole).to have_attributes(
          product:,
          quantity: 2,
          rent: true
        )
      end

  test "updates quantity and rent when the item is already in the wishlist" do
        product = create(:subscription_product_with_versions)
        product.update!(quantity_enabled: true, purchase_type: :buy_and_rent, rental_price_cents: 100)

        wishlist_product = create(:wishlist_product, wishlist:, product:, quantity: 2, rent: false, recurrence: BasePrice::Recurrence::MONTHLY, variant: product.alive_variants.first)

        expect do
          post :create, params: {
            wishlist_id: wishlist.external_id,
            wishlist_product: {
              product_id: product.external_id,
              quantity: 5,
              rent: true,
              recurrence: BasePrice::Recurrence::MONTHLY,
              option_id: product.options.first[:id]
            }
          }
        end.not_to change(WishlistProduct, :count)

        expect(wishlist_product.reload).to have_attributes(
          quantity: 5,
          rent: true
        )
      end

  test "adds a product again if it was deleted" do
        wishlist_product = create(:wishlist_product, wishlist:, product:)
        wishlist_product.mark_deleted!

        expect do
          post :create, params: { wishlist_id: wishlist.external_id, wishlist_product: { product_id: product.external_id } }
        end.to change(wishlist.wishlist_products, :count).from(1).to(2)

        expect(wishlist.wishlist_products.reload.last).to have_attributes(wishlist:, product:)
      end

  context_ "when the wishlist does not have followers" do
  test "does not schedule an email job" do
          post :create, params: { wishlist_id: wishlist.external_id, wishlist_product: { product_id: product.external_id } }

          expect(SendWishlistUpdatedEmailsJob.jobs.size).to eq(0)
        end
      end

  context_ "when the wishlist has followers" do
        before { create(:wishlist_follower, wishlist:) }

  test "schedules an email job" do
          post :create, params: { wishlist_id: wishlist.external_id, wishlist_product: { product_id: product.external_id } }

          expect(SendWishlistUpdatedEmailsJob).to have_enqueued_sidekiq_job(wishlist.id, [wishlist.wishlist_products.reload.last.id])
        end
      end

  test "renders validation errors" do
        product = create(:subscription_product)

        expect do
          post :create, params: {
            wishlist_id: wishlist.external_id,
            wishlist_product: {
              product_id: product.external_id
            }
          }
        end.not_to change(WishlistProduct, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to eq("error" => "Recurrence is not included in the list")
      end
    end

  context_ "GET index" do
  test "lists the products in the wishlist" do
        wishlist_product1 = create(:wishlist_product, wishlist:)
        wishlist_product2 = create(:wishlist_product, wishlist:)
        create(:wishlist_product) # another wishlist product

        get :index, params: { wishlist_id: wishlist.external_id }

        expect(response).to be_successful
        expect(response.parsed_body["items"].map { |wp| wp["id"] }).to match_array([wishlist_product1.external_id, wishlist_product2.external_id])
      end

  context_ "when logged out" do
        before do
          sign_out(user)
        end

  test "lists the products in the wishlist" do
          wishlist_product1 = create(:wishlist_product, wishlist:)
          wishlist_product2 = create(:wishlist_product, wishlist:)
          create(:wishlist_product) # another wishlist product

          get :index, params: { wishlist_id: wishlist.external_id }

          expect(response).to be_successful
          expect(response.parsed_body["items"].map { |wp| wp["id"] }).to match_array([wishlist_product1.external_id, wishlist_product2.external_id])
        end
      end
    end

  context_ "DELETE destroy" do
      let(:wishlist_product) { create(:wishlist_product, wishlist:) }

      it_behaves_like "authorize called for action", :delete, :destroy do
        let(:record) { wishlist_product }
        let(:request_params) { { wishlist_id: wishlist.external_id, id: wishlist_product.external_id } }
      end

  test "marks the wishlist product as deleted" do
        delete :destroy, params: { wishlist_id: wishlist.external_id, id: wishlist_product.external_id }

        expect(response).to be_successful
        expect(wishlist_product.reload).to be_deleted
      end
    end
  end
end
