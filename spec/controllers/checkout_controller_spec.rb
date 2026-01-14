# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe CheckoutController do
  describe "GET index" do
    it "returns HTTP success and assigns correct instance variables" do
      get :index

      expect(assigns[:hide_layouts]).to eq(true)
      expect(assigns[:on_checkout_page]).to eq(true)
      expect(response).to be_successful
    end

    describe "process_cart_id_param check" do
      let(:user) { create(:user) }
      let(:cart) { create(:cart, user:) }
      let(:secure_id) { cart.secure_external_id(scope: "cart_login") }

      context "when user is logged in" do
        before do
          sign_in user
        end

        it "does not redirect when cart_id is blank" do
          get :index

          expect(response).to be_successful
        end

        it "redirects to the same path removing the `cart_id` query param" do
          guest_cart = create(:cart, :guest)
          get :index, params: { cart_id: guest_cart.secure_external_id(scope: "cart_login") }

          expect(response).to redirect_to(checkout_index_path(referrer: UrlService.discover_domain_with_protocol))
        end
      end

      context "when user is not logged in" do
        it "does not redirect when `cart_id` is blank" do
          get :index

          expect(response).to be_successful
        end

        it "redirects to the same path when `cart_id` is not found" do
          get :index, params: { cart_id: "no-such-cart" }

          expect(response).to redirect_to(checkout_index_path(referrer: UrlService.discover_domain_with_protocol))
        end

        it "redirects to the same path when an OLD/INSECURE external_id is used" do
          harvested_id = build(:product, id: cart.id).external_id

          get :index, params: { cart_id: harvested_id }

          expect(response).to redirect_to(checkout_index_path(referrer: UrlService.discover_domain_with_protocol))
          expect(response.location).not_to include("email=")
        end

        it "redirects to the same path when the cart for `cart_id` is deleted" do
          cart.mark_deleted!

          get :index, params: { cart_id: secure_id }

          expect(response).to redirect_to(checkout_index_path(referrer: UrlService.discover_domain_with_protocol))
        end

        context "when the cart matching the `cart_id` query param belongs to a user" do
          it "redirects to the login page path with `next` param set to the checkout path" do
            get :index, params: { cart_id: secure_id }

            expect(response).to redirect_to(login_url(next: checkout_index_path(referrer: UrlService.discover_domain_with_protocol), email: cart.user.email))
          end
        end

        context "when the cart matching the `cart_id` query param has the `browser_guid` same as the current `_gumroad_guid` cookie value"  do
          it "redirects to the same path without modifying the cart" do
            browser_guid = SecureRandom.uuid
            cookies[:_gumroad_guid] = browser_guid
            cart = create(:cart, :guest, browser_guid:)
            valid_id = cart.secure_external_id(scope: "cart_login")

            expect do
              expect do
                get :index, params: { cart_id: valid_id }
              end.not_to change { Cart.alive.count }
            end.not_to change { cart.reload }

            expect(response).to redirect_to(checkout_index_path(referrer: UrlService.discover_domain_with_protocol))
          end
        end

        context "when the cart matching the `cart_id` query param has the `browser_guid` different from the current `_gumroad_guid` cookie value" do
          it "merges the current guest cart with the cart matching the `cart_id` query param" do
            product1 = create(:product)
            product2 = create(:product)

            cart = create(:cart, :guest, browser_guid: SecureRandom.uuid)
            create(:cart_product, cart:, product: product1)

            browser_guid = SecureRandom.uuid
            cookies[:_gumroad_guid] = browser_guid
            current_guest_cart = create(:cart, :guest, browser_guid:, email: "john@example.com")
            create(:cart_product, cart: current_guest_cart, product: product2)

            valid_id = cart.secure_external_id(scope: "cart_login")

            expect do
              get :index, params: { cart_id: valid_id }
            end.to change { Cart.alive.count }.from(2).to(1)

            expect(response).to redirect_to(checkout_index_path(referrer: UrlService.discover_domain_with_protocol))
            expect(Cart.alive.sole.id).to eq(cart.id)
            expect(current_guest_cart.reload).to be_deleted
            expect(cart.reload.email).to eq("john@example.com")
            expect(cart.alive_cart_products.pluck(:product_id)).to match_array([product1.id, product2.id])
          end
        end
      end
    end
  end
end
