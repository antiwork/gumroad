# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/collaborator_access"
require "inertia_rails/rspec"

describe Products::ProductController, inertia: true do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }

  include_context "with user signed in as admin for seller"

  describe "GET edit" do
    it_behaves_like "authorize called for action", :get, :edit do
      let(:record) { product }
      let(:request_params) { { product_id: product.unique_permalink } }
    end

    it "renders the Products/Product/Edit component with expected props" do
      get :edit, params: { product_id: product.unique_permalink }

      expect(response).to be_successful
      expect(inertia.component).to eq("Products/Product/Edit")
      expect(inertia.props.keys).to include(:id, :unique_permalink, :product, :seller)
      expect(inertia.props[:id]).to eq(product.external_id)
      expect(inertia.props[:unique_permalink]).to eq(product.unique_permalink)
      expect(inertia.props[:product]).to be_a(Hash)
      expect(inertia.props[:product][:name]).to eq(product.name)
      expect(inertia.props[:product][:is_published]).to eq(!product.draft && product.alive?)
      expect(inertia.props[:product][:native_type]).to eq(product.native_type)
    end

    context "when not authorized" do
      let(:other_user) { create(:user) }

      before { sign_in other_user }

      it "redirects to product page" do
        get :edit, params: { product_id: product.unique_permalink }
        expect(response).to redirect_to(short_link_path(product))
      end
    end

    context "with admin user signed in" do
      let(:admin) { create(:admin_user) }

      before { sign_in admin }

      it "renders the page" do
        get :edit, params: { product_id: product.unique_permalink }
        expect(response).to have_http_status(:ok)
      end
    end

    context "when the product is a bundle" do
      let(:bundle) { create(:product, :bundle, user: seller) }

      it "redirects to the bundle edit page" do
        sign_in seller
        get :edit, params: { product_id: bundle.unique_permalink }
        expect(response).to redirect_to(bundle_path(bundle.external_id))
      end
    end
  end

  describe "PATCH update" do
    let(:params) do
      {
        product_id: product.unique_permalink,
        product: {
          name: "Updated Name",
          description: "Updated Description"
        }
      }
    end

    it_behaves_like "authorize called for action", :put, :update do
      let(:record) { product }
      let(:request_params) { params }
      let(:request_format) { :html }
    end

    context "with Inertia request" do
      before { request.headers["X-Inertia"] = "true" }

      it_behaves_like "collaborator can access", :put, :update do
        let(:request_params) { params }
        let(:response_status) { 303 }
      end

      it "updates the product and redirects to edit path" do
        put :update, params: params

        expect(product.reload.name).to eq("Updated Name")
        expect(product.description).to eq("Updated Description")
        expect(response).to redirect_to(edit_product_product_path(product.unique_permalink))
        expect(flash[:notice]).to eq("Changes saved!")
      end

      it "marks the product as allowing display of sales count when should_show_sales_count is true" do
        product.update!(should_show_sales_count: false)
        put :update, params: {
          product_id: product.unique_permalink,
          product: { name: product.name, should_show_sales_count: true }
        }
        expect(product.reload.should_show_sales_count).to be(true)
        expect(response).to redirect_to(edit_product_product_path(product.unique_permalink))
      end

      it "marks the product as not allowing display of sales count when should_show_sales_count is false" do
        product.update!(should_show_sales_count: true)
        put :update, params: {
          product_id: product.unique_permalink,
          product: { name: product.name, should_show_sales_count: false }
        }
        expect(product.reload.should_show_sales_count).to be(false)
        expect(response).to redirect_to(edit_product_product_path(product.unique_permalink))
      end
    end

    context "when product is physical" do
      let(:physical_product) { create(:physical_product, user: seller) }
      let(:update_params) do
        {
          product_id: physical_product.unique_permalink,
          product: {
            name: physical_product.name,
            shipping_destinations: [
              { country_code: "ELSEWHERE", one_item_rate_cents: 0, multiple_items_rate_cents: 0 }
            ]
          }
        }
      end

      before { request.headers["X-Inertia"] = "true" }

      it "updates shipping destinations" do
        put :update, params: update_params
        expect(physical_product.reload.shipping_destinations.count).to eq(1)
        expect(physical_product.shipping_destinations.first.country_code).to eq("ELSEWHERE")
        expect(response).to redirect_to(edit_product_product_path(physical_product.unique_permalink))
      end
    end

    context "when product_refund_policy_enabled is toggled" do
      before { request.headers["X-Inertia"] = "true" }

      it "enables product-level refund policy when product_refund_policy_enabled is true" do
        product.update!(product_refund_policy_enabled: false)
        put :update, params: {
          product_id: product.unique_permalink,
          product: { name: product.name, product_refund_policy_enabled: true }
        }
        expect(product.reload.product_refund_policy_enabled?).to be(true)
        expect(response).to redirect_to(edit_product_product_path(product.unique_permalink))
      end

      it "disables product-level refund policy when product_refund_policy_enabled is false" do
        product.update!(product_refund_policy_enabled: true)
        put :update, params: {
          product_id: product.unique_permalink,
          product: { name: product.name, product_refund_policy_enabled: false }
        }
        expect(product.reload.product_refund_policy_enabled?).to be(false)
        expect(response).to redirect_to(edit_product_product_path(product.unique_permalink))
      end
    end

    context "when custom_attributes are updated" do
      before { request.headers["X-Inertia"] = "true" }

      it "saves custom attributes and filters out entries with blank name and value" do
        put :update, params: {
          product_id: product.unique_permalink,
          product: {
            name: product.name,
            custom_attributes: [
              { name: "Size", value: "Large" },
              { name: "", value: "ignored" },
              { name: "Color", value: "Red" }
            ]
          }
        }
        expect(response).to redirect_to(edit_product_product_path(product.unique_permalink))
        saved = product.reload.custom_attributes
        expect(saved.size).to eq(2)
        expect(saved.map { _1["name"] }).to contain_exactly("Size", "Color")
        expect(saved.find { _1["name"] == "Size" }["value"]).to eq("Large")
      end
    end

    context "when section_ids (profile sections) are updated" do
      let!(:profile_section1) { create(:seller_profile_products_section, seller:, shown_products: [product.id]) }
      let!(:profile_section2) { create(:seller_profile_products_section, seller:) }

      before do
        request.headers["X-Inertia"] = "true"
        seller.reload
      end

      it "updates which profile sections show the product" do
        put :update, params: {
          product_id: product.unique_permalink,
          product: { name: product.name, section_ids: [profile_section2.external_id] }
        }
        expect(response).to redirect_to(edit_product_product_path(product.unique_permalink))
        expect(profile_section1.reload.shown_products).not_to include(product.id)
        expect(profile_section2.reload.shown_products).to include(product.id)
      end
    end

    context "when product is coffee and has variants" do
      let(:seller) { create(:named_seller, :eligible_for_service_products) }
      let(:coffee_product) { create(:product, user: seller, native_type: Link::NATIVE_TYPE_COFFEE) }

      before { request.headers["X-Inertia"] = "true" }

      it "sets suggested_price_cents from the max price_difference_cents of variants" do
        put :update, params: {
          product_id: coffee_product.unique_permalink,
          product: {
            name: coffee_product.name,
            variants: [
              { name: "Small", price_difference_cents: 100 },
              { name: "Medium", price_difference_cents: 300 },
              { name: "Large", price_difference_cents: 200 }
            ]
          }
        }
        expect(response).to redirect_to(edit_product_product_path(coffee_product.unique_permalink))
        expect(coffee_product.reload.suggested_price_cents).to eq(300)
      end
    end
  end
end
