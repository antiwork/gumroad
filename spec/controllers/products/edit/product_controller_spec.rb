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

    # LinkPolicy permitted params: verify params we added are not stripped and are applied
    context "when custom_attributes include :description (permitted by LinkPolicy)" do
      before { request.headers["X-Inertia"] = "true" }

      it "saves custom attributes with description key (not stripped by strong params)" do
        put :update, params: {
          product_id: product.unique_permalink,
          product: {
            name: product.name,
            custom_attributes: [
              { name: "Label", description: "Detail value" }
            ]
          }
        }
        expect(response).to redirect_to(edit_product_product_path(product.unique_permalink))
        saved = product.reload.custom_attributes
        expect(saved.size).to eq(1)
        expect(saved.first["name"]).to eq("Label")
        expect(saved.first["description"]).to eq("Detail value")
      end
    end

    context "when custom_button_text_option and custom_summary are sent (permitted by LinkPolicy)" do
      before { request.headers["X-Inertia"] = "true" }

      it "saves custom_button_text_option and custom_summary" do
        put :update, params: {
          product_id: product.unique_permalink,
          product: {
            name: product.name,
            custom_button_text_option: "donate_prompt",
            custom_summary: "A short summary of the product."
          }
        }
        expect(response).to redirect_to(edit_product_product_path(product.unique_permalink))
        product.reload
        expect(product.custom_button_text_option).to eq("donate_prompt")
        expect(product.custom_summary).to eq("A short summary of the product.")
      end
    end

    context "when cancellation_discount is sent (permitted by LinkPolicy)" do
      let(:membership) { create(:membership_product_with_preset_tiered_pricing, user: seller) }

      before do
        request.headers["X-Inertia"] = "true"
        Feature.activate_user(:cancellation_discounts, seller)
      end

      it "saves cancellation_discount via SaveCancellationDiscountService" do
        tier_category = membership.variant_categories_alive.first
        variants_param = tier_category.variants.map { |v| { "id" => v.external_id, "name" => v.name } }

        put :update, params: {
          product_id: membership.unique_permalink,
          product: {
            name: membership.name,
            "variants" => variants_param,
            "cancellation_discount" => {
              "duration_in_billing_cycles" => 2,
              "discount" => { "type" => "percent", "percents" => 10 }
            }
          }
        }
        expect(response).to redirect_to(edit_product_product_path(membership.unique_permalink))
        expect(flash[:notice]).to eq("Changes saved!")
        membership.reload
        expect(membership.cancellation_discount_offer_code).to be_present
        expect(membership.cancellation_discount_offer_code.amount_percentage).to eq(10)
        expect(membership.cancellation_discount_offer_code.duration_in_billing_cycles).to eq(2)
      end
    end

    context "when call_limitation_info is sent (permitted by LinkPolicy)" do
      let(:seller) { create(:named_seller, :eligible_for_service_products) }
      let(:call_product) { create(:call_product, user: seller) }

      before { request.headers["X-Inertia"] = "true" }

      it "updates call_limitation_info" do
        expect(call_product.call_limitation_info.minimum_notice_in_minutes).to eq(CallLimitationInfo::DEFAULT_MINIMUM_NOTICE_IN_MINUTES)

        duration_category = call_product.variant_categories_alive.first
        variants_param = duration_category.variants.map { |v| { id: v.external_id, name: v.name, duration_in_minutes: v.duration_in_minutes } }

        put :update, params: {
          product_id: call_product.unique_permalink,
          product: {
            name: call_product.name,
            variants: variants_param,
            call_limitation_info: {
              minimum_notice_in_minutes: 60,
              maximum_calls_per_day: 3
            }
          }
        }

        expect(response).to redirect_to(edit_product_product_path(call_product.unique_permalink))
        expect(flash[:notice]).to eq("Changes saved!")
        call_product.reload
        expect(call_product.call_limitation_info.minimum_notice_in_minutes).to eq(60)
        expect(call_product.call_limitation_info.maximum_calls_per_day).to eq(3)
      end
    end

    context "when installment_plan is sent (permitted by LinkPolicy)" do
      let(:digital_product) { create(:product, user: seller, native_type: Link::NATIVE_TYPE_DIGITAL, price_cents: 3000) }

      before { request.headers["X-Inertia"] = "true" }

      it "creates or updates installment_plan" do
        expect(digital_product.installment_plan).to be_nil

        put :update, params: {
          product_id: digital_product.unique_permalink,
          product: {
            name: digital_product.name,
            installment_plan: { number_of_installments: 4 }
          }
        }
        expect(response).to redirect_to(edit_product_product_path(digital_product.unique_permalink))
        digital_product.reload
        expect(digital_product.installment_plan).to be_present
        expect(digital_product.installment_plan.number_of_installments).to eq(4)
      end
    end
  end
end
