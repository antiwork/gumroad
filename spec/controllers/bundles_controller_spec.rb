# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe BundlesController do
  let(:seller) { create(:named_seller, :eligible_for_service_products) }
  let(:bundle) { create(:product, :bundle, user: seller, price_cents: 2000) }

  include_context "with user signed in as admin for seller"

  describe "GET show" do
    render_views

    it "initializes the presenter with the correct arguments and sets the title to the bundle's name" do
      expect(BundlePresenter).to receive(:new).with(bundle:).and_call_original
      get :show, params: { id: bundle.external_id }
      expect(response.body).to have_selector("title:contains('#{bundle.name}')", visible: false)
      expect(response).to be_successful
    end

    context "when the bundle doesn't exist" do
      it "returns 404" do
        expect { get :show, params: { id: "" } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "product is membership" do
      let(:product) { create(:membership_product) }

      it "returns 404" do
        expect { get :show, params: { id: product.external_id } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "product has variants" do
      let(:product) { create(:product_with_digital_versions) }

      it "returns 404" do
        expect { get :show, params: { id: product.external_id } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "GET create_from_email" do
    let!(:product) { create(:product, user: seller) }
    let!(:versioned_product) { create(:product_with_digital_versions, user: seller) }

    it_behaves_like "authorize called for action", :get, :create_from_email do
      let(:policy_klass) { LinkPolicy }
      let(:record) { Link }
      let(:policy_method) { :create? }
    end

    it "creates the bundle and redirects to the edit page" do
      get :create_from_email, params: { type: Product::BundlesMarketing::BEST_SELLING_BUNDLE, price: 100, products: [product.external_id, versioned_product.external_id] }

      bundle = Link.last
      expect(response).to redirect_to bundle_path(bundle.external_id)
      expect(bundle.name).to eq("Best Selling Bundle")
      expect(bundle.price_cents).to eq(100)
      expect(bundle.is_bundle).to eq(true)
      expect(bundle.from_bundle_marketing).to eq(true)
      expect(bundle.native_type).to eq(Link::NATIVE_TYPE_BUNDLE)
      expect(bundle.price_currency_type).to eq(Currency::USD)
      bundle_product1 = bundle.bundle_products.first
      expect(bundle_product1.product).to eq(product)
      expect(bundle_product1.variant).to be_nil
      expect(bundle_product1.quantity).to eq(1)
      bundle_product2 = bundle.bundle_products.second
      expect(bundle_product2.product).to eq(versioned_product)
      expect(bundle_product2.variant).to eq(versioned_product.alive_variants.first)
      expect(bundle_product2.quantity).to eq(1)
    end
  end

  describe "GET products" do
    let!(:product) { create(:product, user: seller, name: "Product") }
    let!(:versioned_product) { create(:product_with_digital_versions, name: "Versioned product", user: seller) }
    let!(:bundle_product) { create(:product, :bundle, user: seller, name: "Bundle product") }
    let!(:membership_product) { create(:membership_product_with_preset_tiered_pricing, user: seller, name: "Membership product") }
    let!(:call_product) { create(:call_product, user: seller, name: "Call product") }
    let!(:archived_product) { create(:product, user: seller, name: "Archived product", archived: true) }

    before do
      index_model_records(Link)
      stub_const("BundlesController::PER_PAGE", 1)
    end

    it_behaves_like "authorize called for action", :get, :products do
      let(:policy_klass) { LinkPolicy }
      let(:record) { Link }
      let(:policy_method) { :index? }
    end

    it "returns products that can be added to a bundle" do
      get :products, params: { all: true, product_id: bundle_product.bundle_products.first.product.external_id }
      ids = response.parsed_body["products"].map { _1["id"] }
      expect(ids).to match_array([product, versioned_product, archived_product, bundle_product.bundle_products.second.product].map(&:external_id))
    end
  end

  describe "PUT update" do
    let(:product) { create(:product, user: seller) }
    let(:asset_previews) { create_list(:asset_preview, 2, link: bundle) }
    let(:versioned_product) { create(:product_with_digital_versions, user: seller) }
    let(:profile_section1) { create(:seller_profile_products_section, seller:, shown_products: [bundle.id]) }
    let(:profile_section2) { create(:seller_profile_products_section, seller:) }
    let!(:purchase) { create(:purchase, link: bundle) }
    let(:bundle_params) do
      {
        id: bundle.external_id,
        name: "New name",
        description: "New description",
        custom_permalink: "new-permalink",
        price_cents: 1000,
        customizable_price: true,
        suggested_price_cents: 2000,
        custom_button_text_option: "buy_this_prompt",
        custom_summary: "Custom summary",
        custom_attributes: [{ "name" => "Detail 1", "value" => "Value 1" }],
        covers: [asset_previews.second.guid, asset_previews.first.guid],
        max_purchase_count: 10,
        quantity_enabled: true,
        should_show_sales_count: true,
        taxonomy_id: 1,
        tags: ["tag1", "tag2", "tag3"],
        display_product_reviews: false,
        is_adult: true,
        discover_fee_per_thousand: 400,
        is_epublication: true,
        product_refund_policy_enabled: true,
        refund_policy: {
          title: "New refund policy",
          fine_print: "I really hate being small",
        },
        section_ids: [profile_section2.external_id],
        products: [
          {
            product_id: bundle.bundle_products.first.product.external_id,
            variant_id: nil,
            quantity: 3,
          },
          {
            product_id: product.external_id,
            quantity: 1,
          },
          {
            product_id: versioned_product.external_id,
            variant_id: versioned_product.alive_variants.first.external_id,
            quantity: 2,
          }
        ]
      }
    end

    it_behaves_like "authorize called for action", :put, :update do
      let(:policy_klass) { LinkPolicy }
      let(:record) { bundle }
      let(:request_params) { { id: bundle.external_id } }
    end

    before { index_model_records(Purchase) }

    it "updates the bundle" do
      expect do
        put :update, params: bundle_params, as: :json
        bundle.reload
      end.to change { bundle.name }.from("Bundle").to("New name")
      .and change { bundle.description }.from("This is a bundle of products").to("New description")
      .and change { bundle.custom_permalink }.from(nil).to("new-permalink")
      .and change { bundle.price_cents }.from(2000).to(1000)
      .and change { bundle.customizable_price? }.from(false).to(true)
      .and change { bundle.suggested_price_cents }.from(nil).to(2000)
      .and change { bundle.custom_button_text_option }.from(nil).to("buy_this_prompt")
      .and change { bundle.custom_attributes }.from([]).to([{ "name" => "Detail 1", "value" => "Value 1" }])
      .and change { bundle.custom_summary }.from(nil).to("Custom summary")
      .and change { bundle.display_asset_previews.map(&:id) }.from([asset_previews.first.id, asset_previews.second.id]).to([asset_previews.second.id, asset_previews.first.id])
      .and change { bundle.max_purchase_count }.from(nil).to(10)
      .and change { bundle.quantity_enabled }.from(false).to(true)
      .and change { bundle.should_show_sales_count }.from(false).to(true)
      .and change { bundle.taxonomy_id }.from(nil).to(1)
      .and change { bundle.tags.pluck(:name) }.from([]).to(["tag1", "tag2", "tag3"])
      .and change { bundle.display_product_reviews }.from(true).to(false)
      .and change { bundle.is_adult }.from(false).to(true)
      .and change { bundle.discover_fee_per_thousand }.from(100).to(400)
      .and change { bundle.is_epublication }.from(false).to(true)
      .and not_change { bundle.product_refund_policy_enabled }
      .and not_change { bundle.product_refund_policy&.title }
      .and not_change { bundle.product_refund_policy&.fine_print }
      .and change { bundle.has_outdated_purchases }.from(false).to(true)
      .and change { profile_section1.reload.shown_products }.from([bundle.id]).to([])
      .and change { profile_section2.reload.shown_products }.from([]).to([bundle.id])

      expect(response).to be_successful

      deleted_bundle_products = bundle.bundle_products.deleted
      expect(deleted_bundle_products.first.deleted_at).to be_present

      new_bundle_products = bundle.bundle_products.alive
      expect(new_bundle_products.first.product).to eq(bundle.bundle_products.first.product)
      expect(new_bundle_products.first.variant).to be_nil
      expect(new_bundle_products.first.bundle).to eq(bundle)
      expect(new_bundle_products.first.quantity).to eq(3)
      expect(new_bundle_products.first.deleted_at).to be_nil

      expect(new_bundle_products.second.product).to eq(product)
      expect(new_bundle_products.second.variant).to be_nil
      expect(new_bundle_products.second.bundle).to eq(bundle)
      expect(new_bundle_products.second.quantity).to eq(1)
      expect(new_bundle_products.second.deleted_at).to be_nil

      expect(new_bundle_products.third.product).to eq(versioned_product)
      expect(new_bundle_products.third.variant).to eq(versioned_product.alive_variants.first)
      expect(new_bundle_products.third.bundle).to eq(bundle)
      expect(new_bundle_products.third.quantity).to eq(2)
      expect(new_bundle_products.third.deleted_at).to be_nil
    end

    describe "installment plans" do
      let(:bundle_params) { super().merge(customizable_price: false) }

      let(:commission_product) { create(:commission_product, user: seller) }
      let(:course_product) { create(:product, native_type: Link::NATIVE_TYPE_COURSE, user: seller) }
      let(:digital_product) { create(:product, native_type: Link::NATIVE_TYPE_DIGITAL, user: seller) }

      context "when bundle is eligible for installment plans" do
        context "with no existing plans" do
          it "creates a new installment plan" do
            params = bundle_params.merge(installment_plan: { number_of_installments: 3 })

            expect { put :update, params: params, as: :json }
              .to change { ProductInstallmentPlan.alive.count }.by(1)

            plan = bundle.reload.installment_plan
            expect(plan.number_of_installments).to eq(3)
            expect(plan.recurrence).to eq("monthly")
            expect(response.status).to eq(204)
          end
        end

        context "with an existing plan" do
          let!(:existing_plan) do
            create(
              :product_installment_plan,
              link: bundle,
              number_of_installments: 2,
            )
          end

          it "does not allow adding products that are not eligible for installment plans" do
            params = bundle_params.merge(
              installment_plan: { number_of_installments: 2 },
              products: [
                {
                  product_id: commission_product.external_id,
                  quantity: 1
                },
              ]
            )

            expect { put :update, params: params, as: :json }
              .not_to change { bundle.bundle_products.count }

            expect(response.status).to eq(422)
            expect(response.parsed_body["error_message"]).to include("Installment plan is not available for the bundled product")
            expect(bundle.reload.bundle_products.map(&:product)).not_to include(commission_product)
          end

          context "with no existing payment options" do
            it "destroys the existing plan and creates a new plan" do
              params = bundle_params.merge(installment_plan: { number_of_installments: 4 })

              expect { put :update, params: params, as: :json }
                .not_to change { ProductInstallmentPlan.count }

              expect { existing_plan.reload }.to raise_error(ActiveRecord::RecordNotFound)

              new_plan = bundle.reload.installment_plan
              expect(new_plan).to have_attributes(
                number_of_installments: 4,
                recurrence: "monthly"
              )
              expect(response.status).to eq(204)
            end
          end

          context "with existing payment options" do
            before do
              create(:payment_option, installment_plan: existing_plan)
              create(:installment_plan_purchase, link: bundle)
            end

            it "soft deletes the existing plan and creates a new plan" do
              params = bundle_params.merge(installment_plan: { number_of_installments: 4 })

              expect { put :update, params: params, as: :json }
                .to change { existing_plan.reload.deleted_at }.from(nil)

              new_plan = bundle.reload.installment_plan
              expect(new_plan).to have_attributes(
                number_of_installments: 4,
                recurrence: "monthly"
              )
              expect(new_plan).not_to eq(existing_plan)
              expect(response.status).to eq(204)
            end
          end
        end

        context "removing an existing plan" do
          let!(:existing_plan) do
            create(
              :product_installment_plan,
              link: bundle,
              number_of_installments: 2,
              recurrence: "monthly"
            )
          end

          context "with no existing payment options" do
            it "destroys the existing plan" do
              params = bundle_params.merge(installment_plan: nil)

              expect { put :update, params: params, as: :json }
                .to change { ProductInstallmentPlan.count }.by(-1)

              expect { existing_plan.reload }.to raise_error(ActiveRecord::RecordNotFound)
              expect(bundle.reload.installment_plan).to be_nil
              expect(response.status).to eq(204)
            end
          end

          context "with existing payment options" do
            before do
              create(:payment_option, installment_plan: existing_plan)
              create(:installment_plan_purchase, link: bundle)
            end

            it "soft deletes the existing plan" do
              params = bundle_params.merge(installment_plan: nil)

              expect { put :update, params: params, as: :json }
                .to change { existing_plan.reload.deleted_at }.from(nil)

              expect(bundle.reload.installment_plan).to be_nil
              expect(response.status).to eq(204)
            end
          end
        end
      end

      context "when bundle is not eligible for installment plans" do
        let!(:bundle_product) { create(:bundle_product, bundle: bundle, product: commission_product) }

        it "does not create an installment plan" do
          params = bundle_params.merge(installment_plan: { number_of_installments: 3 })

          expect { put :update, params: params, as: :json }
            .not_to change { ProductInstallmentPlan.count }

          expect(bundle.reload.installment_plan).to be_nil
          expect(response.status).to eq(422)
          expect(response.parsed_body["error_message"]).to include("Installment plan is not available for the bundled product")
        end
      end

      context "when bundle has customizable price" do
        before { bundle.update!(customizable_price: true) }

        it "does not create an installment plan" do
          params = bundle_params.merge(
            customizable_price: true,
            installment_plan: { number_of_installments: 3 }
          )

          expect { put :update, params: params, as: :json }
            .not_to change { ProductInstallmentPlan.count }

          expect(bundle.reload.installment_plan).to be_nil
          expect(response.status).to eq(422)
          expect(response.parsed_body["error_message"]).to include("Installment plans are not available for \"pay what you want\" pricing")
        end
      end
    end

    context "when seller_refund_policy_disabled_for_all feature flag is set to true" do
      before do
        Feature.activate(:seller_refund_policy_disabled_for_all)
      end

      it "updates the bundle refund policy" do
        put :update, params: bundle_params, as: :json
        bundle.reload
        expect(bundle.product_refund_policy_enabled).to be(true)
        expect(bundle.product_refund_policy.title).to eq("30-day money back guarantee")
        expect(bundle.product_refund_policy.fine_print).to eq("I really hate being small")
      end
    end

    context "when seller refund policy is set to false" do
      before do
        seller.update!(refund_policy_enabled: false)
      end

      it "updates the bundle refund policy" do
        put :update, params: bundle_params, as: :json
        bundle.reload
        expect(bundle.product_refund_policy_enabled).to be(true)
        expect(bundle.product_refund_policy.title).to eq("30-day money back guarantee")
        expect(bundle.product_refund_policy.fine_print).to eq("I really hate being small")
      end

      context "with bundle refund policy enabled" do
        before do
          bundle.update!(product_refund_policy_enabled: true)
        end

        it "disables the product refund policy" do
          bundle_params[:product_refund_policy_enabled] = false
          put :update, params: bundle_params, as: :json
          bundle.reload
          expect(bundle.product_refund_policy_enabled).to be(false)
          expect(bundle.product_refund_policy).to be_nil
        end
      end
    end

    context "adding a call to a bundle" do
      let(:call_product) { create(:call_product, user: seller) }

      it "does not make any changes to the bundle and returns an error" do
        expect do
          put :update, params: {
            id: bundle.external_id,
            products: [
              {
                product_id: call_product.external_id,
                variant_id: call_product.variants.first.external_id,
                quantity: 1
              },
              { product_id: product.external_id, quantity: 1, },
            ]
          }
          bundle.reload
        end.to_not change { bundle.bundle_products.count }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["error_message"]).to eq("Validation failed: A call product cannot be added to a bundle")
      end
    end

    context "product is not a bundle" do
      let(:product) { create(:product, user: seller) }

      it "converts it to a bundle" do
        expect do
          put :update, params: {
            id: product.external_id,
            products: [
              {
                product_id: versioned_product.external_id,
                variant_id: versioned_product.alive_variants.first.external_id,
                quantity: 1,
              },
            ]
          }
          product.reload
        end.to change { product.is_bundle }.from(false).to(true)
           .and change { product.native_type }.from(Link::NATIVE_TYPE_DIGITAL).to(Link::NATIVE_TYPE_BUNDLE)

        expect(product.bundle_products.count).to eq(1)
        expect(product.bundle_products.first.product).to eq(versioned_product)
        expect(product.bundle_products.first.variant).to eq(versioned_product.alive_variants.first)
        expect(product.bundle_products.first.quantity).to eq(1)
      end
    end

    context "when there is a validation error" do
      it "returns the error message" do
        expect do
          put :update, params: {
            id: bundle.external_id,
            custom_permalink: "*",
            bundle_products: [],
          }, as: :json
        end.to change { bundle.bundle_products.count }.by(0)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["error_message"]).to eq("Custom permalink is invalid")
      end
    end

    context "when the bundle doesn't exist" do
      it "returns 404" do
        expect { put :update, params: { id: "" } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "product is a call" do
      let(:product) { create(:call_product) }

      it "returns 404" do
        expect { put :update, params: { id: product.external_id } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "product is membership" do
      let(:product) { create(:membership_product) }

      it "returns 404" do
        expect { put :update, params: { id: product.external_id } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "product has variants" do
      let(:product) { create(:product_with_digital_versions) }

      it "returns 404" do
        expect { put :update, params: { id: product.external_id } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end
