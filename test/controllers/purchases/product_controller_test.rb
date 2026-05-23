# frozen_string_literal: true

require "test_helper"

class PurchasesProductControllerTest < ActionController::TestCase
  self.described_class = Purchases::ProductController
  tests Purchases::ProductController

  # frozen_string_literal: false


  context_ Purchases::ProductController, type: :controller, inertia: true do
    let(:purchase) { create(:purchase) }
    let(:product) { purchase.link }
    let(:seller) { product.user }

  context_ "GET show" do
  test "renders the Inertia component with all required props" do
        get :show, params: { purchase_id: purchase.external_id }

        expect(response).to be_successful
        expect_inertia.to render_component "Purchases/Product/Show"

        expect(inertia.props[:custom_styles]).to eq(seller.seller_profile.custom_styles.to_s)
        expect(inertia.props[:product][:id]).to eq(product.external_id)
        expect(inertia.props[:product][:name]).to eq(product.name)
        expect(inertia.props[:product][:long_url]).to eq(product.long_url)
        expect(inertia.props[:product][:currency_code]).to eq(product.price_currency_type.downcase)
        expect(inertia.props[:product][:price_cents]).to eq(product.price_cents)

        expect(inertia.props[:product][:seller][:name]).to eq(seller.display_name)
      end

  test "404s for an invalid purchase id" do
        expect do
          get :show, params: { purchase_id: "1234" }
        end.to raise_error(ActionController::RoutingError)
      end

  test "adds X-Robots-Tag response header to avoid page indexing" do
        get :show, params: { purchase_id: purchase.external_id }

        expect(response).to be_successful
        expect(response.headers["X-Robots-Tag"]).to eq("noindex")
      end
    end
  end
end
