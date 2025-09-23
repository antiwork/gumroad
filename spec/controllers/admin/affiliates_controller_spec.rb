# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::AffiliatesController do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  before do
    @admin_user = create(:admin_user)
    sign_in @admin_user
  end

  describe "GET 'index'" do
    context "when there's one matching affiliate in search result" do
      before do
        @affiliate_user = create(:direct_affiliate).affiliate_user
      end

      it "redirects to affiliate's admin page" do
        get :index, params: { query: @affiliate_user.email }

        expect(response).to redirect_to admin_affiliate_path(@affiliate_user)
      end
    end

    context "when there are multiple affiliates in search result" do
      before do
        @affiliate_users = 10.times.map do
          user = create(:user, name: "test")
          create(:direct_affiliate, affiliate_user: user)
          user
        end
      end

      it "renders search results" do
        get :index, params: { query: "test" }

        expect(response).to be_successful
        expect(response).to render_template(:index)
        expect(assigns[:users].to_a).to match_array(@affiliate_users)
      end
    end
  end

  describe "GET 'show'" do
    let(:affiliate_user) { create(:user, name: "Sam") }

    context "when affiliate account is present" do
      before do
        create(:direct_affiliate, affiliate_user:)
      end

      it "returns page successfully" do
        get :show, params: { id: affiliate_user.id }

        expect(response).to be_successful
        expect(response.body).to have_text(affiliate_user.name)
        expect(assigns[:title]).to eq "Sam affiliate on Gumroad"
      end

      context "with products" do
        let!(:published_product) { create(:product, name: "Published product") }
        let!(:unpublished_product) { create(:product, name: "Unpublished product", purchase_disabled_at: Time.current) }
        let!(:deleted_product) { create(:product, name: "Deleted product", deleted_at: Time.current) }
        let!(:banned_product) { create(:product, name: "Banned product", banned_at: Time.current) }
        let!(:alive_affiliate) { create(:direct_affiliate, affiliate_user:, products: [published_product, unpublished_product, deleted_product, banned_product]) }

        let!(:product_by_deleted_affiliate) { create(:product, name: "Product by deleted affiliate") }
        let!(:deleted_affiliate) { create(:direct_affiliate, affiliate_user:, products: [product_by_deleted_affiliate], deleted_at: Time.current) }

        it "shows all products except banned or deleted ones" do
          get :show, params: { id: affiliate_user.id }

          expect(response).to be_successful
          expect(response.body).to have_text(published_product.name)
          expect(response.body).to have_text(unpublished_product.name)
          expect(response.body).to_not have_text(deleted_product.name)
          expect(response.body).to_not have_text(banned_product.name)
          expect(response.body).to_not have_text(product_by_deleted_affiliate.name)
          expect(response.body).to_not have_selector("[aria-label='Pagination']")
        end

        context "when there are too many products for one page" do
          let!(:products) do
            create_list(:product, 9) do |product, i|
              product.created_at = Time.current + i.minutes
            end
          end

          before do
            create(:direct_affiliate, affiliate_user:, products:)
          end

          it "paginates the products" do
            get :show, params: { id: affiliate_user.id }

            expect(response).to be_successful
            expect(response.body).to have_text(published_product.name)
            products.each { expect(response.body).to have_text(_1.name) }
            expect(response.body).to_not have_text(unpublished_product.name)
            expect(response.body).to have_selector("[aria-label='Pagination']")
          end
        end
      end
    end

    context "when affiliate account is not present" do
      it "raises ActionController::RoutingError" do
        expect do
          get :show, params: { id: affiliate_user.id }
        end.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end
  end
end
