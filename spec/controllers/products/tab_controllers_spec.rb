# frozen_string_literal: true
require "spec_helper"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe Products::ProductTabController, inertia: true do
  render_views

  let(:seller) { create(:named_seller) }
  include_context "with user signed in as admin for seller"

  let(:product) { create(:product, user: seller) }

  describe "GET edit" do
    it_behaves_like "authorize called for action", :get, :edit do
      let(:record) { product }
      let(:request_params) { { id: product.unique_permalink } }
    end

    it "404s when product is not found" do
      expect { get :edit, params: { id: "not-real" } }.to raise_error(ActionController::RoutingError)
    end

    it "renders Products/Edit/ProductTab with correct props" do
      get :edit, params: { id: product.unique_permalink }
      expect(response).to have_http_status(:ok)
      expect(inertia).to render_component("Products/Edit/ProductTab")
      expect(inertia.props).to include(:product, :id, :unique_permalink, :thumbnail,
                                       :currency_type, :is_tiered_membership, :is_physical,
                                       :profile_sections, :taxonomies, :seller)
    end

    it "includes correct product props" do
      get :edit, params: { id: product.unique_permalink }
      expect(inertia.props[:product]).to include(
        :name, :description, :price_cents, :is_published, :native_type, :variants, :covers
      )
    end

    it "redirects bundle products to bundle edit path" do
      bundle = create(:product, user: seller, native_type: Link::NATIVE_TYPE_BUNDLE, is_bundle: true)
      get :edit, params: { id: bundle.unique_permalink }
      expect(response).to redirect_to(edit_bundle_product_path(bundle.external_id))
    end
  end

  describe "PATCH update" do
    it_behaves_like "authorize called for action", :patch, :update do
      let(:record) { product }
      let(:request_params) { { id: product.unique_permalink, link: { name: "New Name" } } }
    end

    it "404s when product is not found" do
      expect { patch :update, params: { id: "not-real", link: { name: "x" } } }.to raise_error(ActionController::RoutingError)
    end

    it "updates product name" do
      patch :update, params: {
        id: product.unique_permalink,
        link: { name: "Updated Name", lock_version: product.lock_version }
      }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to eq(true)
      expect(product.reload.name).to eq("Updated Name")
    end

    it "returns 409 on stale object (concurrency conflict)" do
      product.update_columns(lock_version: 99)
      patch :update, params: {
        id: product.unique_permalink,
        link: { name: "New Name", lock_version: 0 }
      }
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error"]).to eq("conflict")
    end
  end
end

describe Products::ContentTabController, inertia: true do
  render_views

  let(:seller) { create(:named_seller) }
  include_context "with user signed in as admin for seller"

  let(:product) { create(:product, user: seller) }

  describe "GET edit" do
    it_behaves_like "authorize called for action", :get, :edit do
      let(:record) { product }
      let(:request_params) { { id: product.unique_permalink } }
    end

    it "404s when product is not found" do
      expect { get :edit, params: { id: "not-real" } }.to raise_error(ActionController::RoutingError)
    end

    it "renders Products/Edit/ContentTab with correct props" do
      get :edit, params: { id: product.unique_permalink }
      expect(response).to have_http_status(:ok)
      expect(inertia).to render_component("Products/Edit/ContentTab")
      expect(inertia.props).to include(:product, :id, :unique_permalink, :existing_files)
    end
  end

  describe "PATCH update" do
    it_behaves_like "authorize called for action", :patch, :update do
      let(:record) { product }
      let(:request_params) { { id: product.unique_permalink, link: { preview_url: "https://example.com" } } }
    end

    it "updates preview_url" do
      patch :update, params: {
        id: product.unique_permalink,
        link: { preview_url: "", lock_version: product.lock_version }
      }
      expect(response).to have_http_status(:ok)
    end

    it "returns 409 on stale object" do
      product  # ensure product is created before mock
      product.update_columns(lock_version: 99)
      patch :update, params: {
        id: product.unique_permalink,
        link: { custom_receipt_text: "Thanks!", lock_version: 0 }
      }
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error"]).to eq("conflict")
    end
  end
end

describe Products::ReceiptTabController, inertia: true do
  render_views

  let(:seller) { create(:named_seller) }
  include_context "with user signed in as admin for seller"

  let(:product) { create(:product, user: seller) }

  describe "GET edit" do
    it_behaves_like "authorize called for action", :get, :edit do
      let(:record) { product }
      let(:request_params) { { id: product.unique_permalink } }
    end

    it "404s when product is not found" do
      expect { get :edit, params: { id: "not-real" } }.to raise_error(ActionController::RoutingError)
    end

    it "renders Products/Edit/ReceiptTab with correct props" do
      get :edit, params: { id: product.unique_permalink }
      expect(response).to have_http_status(:ok)
      expect(inertia).to render_component("Products/Edit/ReceiptTab")
      expect(inertia.props).to include(:product, :id, :unique_permalink)
    end

    it "includes receipt-specific product props" do
      get :edit, params: { id: product.unique_permalink }
      expect(inertia.props[:product]).to include(:custom_receipt_text, :custom_view_content_button_text)
    end
  end

  describe "PATCH update" do
    it_behaves_like "authorize called for action", :patch, :update do
      let(:record) { product }
      let(:request_params) { { id: product.unique_permalink, link: { custom_receipt_text: "Thanks!" } } }
    end

    it "updates custom_receipt_text" do
      patch :update, params: {
        id: product.unique_permalink,
        link: { custom_receipt_text: "Thank you!", lock_version: product.lock_version }
      }
      expect(response).to have_http_status(:ok)
      expect(product.reload.custom_receipt_text).to eq("Thank you!")
    end

    it "returns 409 on stale object" do
      product  # ensure product is created before mock
      product.update_columns(lock_version: 99)
      patch :update, params: {
        id: product.unique_permalink,
        link: { custom_receipt_text: "Thanks!", lock_version: 0 }
      }
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error"]).to eq("conflict")
    end
  end
end

describe Products::ShareTabController, inertia: true do
  render_views

  let(:seller) { create(:named_seller) }
  include_context "with user signed in as admin for seller"

  let(:product) { create(:product, user: seller) }

  describe "GET edit" do
    it_behaves_like "authorize called for action", :get, :edit do
      let(:record) { product }
      let(:request_params) { { id: product.unique_permalink } }
    end

    it "404s when product is not found" do
      expect { get :edit, params: { id: "not-real" } }.to raise_error(ActionController::RoutingError)
    end

    it "renders Products/Edit/ShareTab with correct props" do
      get :edit, params: { id: product.unique_permalink }
      expect(response).to have_http_status(:ok)
      expect(inertia).to render_component("Products/Edit/ShareTab")
      expect(inertia.props).to include(:product, :id, :unique_permalink,
                                       :profile_sections, :taxonomies, :is_listed_on_discover)
    end

    it "includes share-specific product props" do
      get :edit, params: { id: product.unique_permalink }
      expect(inertia.props[:product]).to include(
        :tags, :taxonomy_id, :display_product_reviews, :is_adult, :section_ids
      )
    end
  end

  describe "PATCH update" do
    it_behaves_like "authorize called for action", :patch, :update do
      let(:record) { product }
      let(:request_params) { { id: product.unique_permalink, link: { is_adult: true } } }
    end

    it "updates is_adult flag" do
      patch :update, params: {
        id: product.unique_permalink,
        link: { is_adult: true, lock_version: product.lock_version }
      }
      expect(response).to have_http_status(:ok)
      expect(product.reload.is_adult).to eq(true)
    end

    it "updates tags" do
      patch :update, params: {
        id: product.unique_permalink,
        link: { tags: ["ruby", "rails"], lock_version: product.lock_version }
      }
      expect(response).to have_http_status(:ok)
      expect(product.reload.tags.pluck(:name)).to match_array(["ruby", "rails"])
    end

    it "returns 409 on stale object" do
      product  # ensure product is created before mock
      product.update_columns(lock_version: 99)
      patch :update, params: {
        id: product.unique_permalink,
        link: { custom_receipt_text: "Thanks!", lock_version: 0 }
      }
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error"]).to eq("conflict")
    end
  end
end
