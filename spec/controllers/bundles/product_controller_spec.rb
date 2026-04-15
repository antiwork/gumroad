# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe Bundles::ProductController, inertia: true do
  let(:seller) { create(:named_seller, :eligible_for_service_products) }
  let(:bundle) { create(:product, :bundle, user: seller, price_cents: 2000) }

  include_context "with user signed in as admin for seller"

  describe "GET edit" do
    it "renders the Bundles/Product/Edit Inertia component with expected props" do
      get :edit, params: { bundle_id: bundle.external_id }
      expect(response).to be_successful
      expect(inertia.component).to eq("Bundles/Product/Edit")
      expect(controller.send(:page_title)).to eq(bundle.name)

      expect(inertia.props[:id]).to eq(bundle.external_id)
      expect(inertia.props[:unique_permalink]).to eq(bundle.unique_permalink)
      expect(inertia.props[:currency_type]).to eq(bundle.price_currency_type)
      expect(inertia.props[:bundle][:name]).to eq(bundle.name)
      expect(inertia.props[:bundle][:price_cents]).to eq(bundle.price_cents)
      expect(inertia.props[:bundle][:products]).to be_an(Array)
      expect(inertia.props).to have_key(:ratings)
      expect(inertia.props).to have_key(:refund_policies)
    end

    context "when the bundle doesn't exist" do
      it "returns 404" do
        expect { get :edit, params: { bundle_id: "" } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "PUT update" do
    let(:asset_previews) do
      previews = create_list(:asset_preview, 2, link: bundle)
      previews.each do |preview|
        if preview.file.attached?
          preview.file.analyze unless preview.file.analyzed?
          metadata = preview.file.blob.metadata || {}
          unless metadata["height"] && metadata["width"]
            preview.file.blob.update_column(:metadata, metadata.merge("height" => 100, "width" => 100))
          end
        end
      end
      previews
    end
    let(:bundle_params) do
      {
        bundle_id: bundle.external_id,
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
        is_epublication: true,
        product_refund_policy_enabled: true,
        refund_policy: {
          title: "New refund policy",
          fine_print: "I really hate being small",
        },
      }
    end

    it_behaves_like "authorize called for action", :put, :update do
      let(:policy_klass) { LinkPolicy }
      let(:record) { bundle }
      let(:request_params) { { bundle_id: bundle.external_id } }
    end

    before { index_model_records(Purchase) }

    it "updates the bundle and redirects back for published bundle" do
      expect do
        put :update, params: bundle_params
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
      .and change { bundle.is_epublication }.from(false).to(true)
      .and not_change { bundle.product_refund_policy_enabled }
      .and not_change { bundle.product_refund_policy&.title }
      .and not_change { bundle.product_refund_policy&.fine_print }

      expect(response).to redirect_to(edit_bundle_product_path(bundle.external_id))
      expect(flash[:notice]).to eq("Changes saved!")
    end

    context "when bundle is unpublished" do
      let(:bundle) { create(:product, :bundle, :unpublished, user: seller, price_cents: 2000) }

      it "redirects to content page after saving" do
        put :update, params: bundle_params
        expect(response).to redirect_to(edit_bundle_content_path(bundle.external_id))
        expect(flash[:notice]).to eq("Changes saved!")
      end
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

            expect { put :update, params: params }
              .to change { ProductInstallmentPlan.alive.count }.by(1)

            plan = bundle.reload.installment_plan
            expect(plan.number_of_installments).to eq(3)
            expect(plan.recurrence).to eq("monthly")
            expect(response).to redirect_to(edit_bundle_product_path(bundle.external_id))
            expect(flash[:notice]).to eq("Changes saved!")
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

          it "does not allow creating installment plan when bundle has ineligible products" do
            existing_plan.destroy!
            bundle.reload
            create(:bundle_product, bundle: bundle, product: commission_product)

            params = bundle_params.merge(
              installment_plan: { number_of_installments: 2 }
            )

            expect { put :update, params: params }
              .not_to change { bundle.reload.installment_plan }

            expect(response).to redirect_to(edit_bundle_product_path(bundle.external_id))
            expect(flash[:alert]).to include("Installment plan is not available for the bundled product")
          end

          context "with no existing payment options" do
            it "destroys the existing plan and creates a new plan" do
              params = bundle_params.merge(installment_plan: { number_of_installments: 4 })

              expect { put :update, params: params }
                .not_to change { ProductInstallmentPlan.count }

              expect { existing_plan.reload }.to raise_error(ActiveRecord::RecordNotFound)

              new_plan = bundle.reload.installment_plan
              expect(new_plan).to have_attributes(
                number_of_installments: 4,
                recurrence: "monthly"
              )
              expect(response).to redirect_to(edit_bundle_product_path(bundle.external_id))
              expect(flash[:notice]).to eq("Changes saved!")
            end
          end

          context "with existing payment options" do
            before do
              create(:payment_option, installment_plan: existing_plan)
              create(:installment_plan_purchase, link: bundle)
            end

            it "soft deletes the existing plan and creates a new plan" do
              params = bundle_params.merge(installment_plan: { number_of_installments: 4 })

              expect { put :update, params: params }
                .to change { existing_plan.reload.deleted_at }.from(nil)

              new_plan = bundle.reload.installment_plan
              expect(new_plan).to have_attributes(
                number_of_installments: 4,
                recurrence: "monthly"
              )
              expect(new_plan).not_to eq(existing_plan)
              expect(response).to redirect_to(edit_bundle_product_path(bundle.external_id))
              expect(flash[:notice]).to eq("Changes saved!")
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

              expect { put :update, params: params }
                .to change { ProductInstallmentPlan.count }.by(-1)

              expect { existing_plan.reload }.to raise_error(ActiveRecord::RecordNotFound)
              expect(bundle.reload.installment_plan).to be_nil
              expect(response).to redirect_to(edit_bundle_product_path(bundle.external_id))
              expect(flash[:notice]).to eq("Changes saved!")
            end
          end

          context "with existing payment options" do
            before do
              create(:payment_option, installment_plan: existing_plan)
              create(:installment_plan_purchase, link: bundle)
            end

            it "soft deletes the existing plan" do
              params = bundle_params.merge(installment_plan: nil)

              expect { put :update, params: params }
                .to change { existing_plan.reload.deleted_at }.from(nil)

              expect(bundle.reload.installment_plan).to be_nil
              expect(response).to redirect_to(edit_bundle_product_path(bundle.external_id))
              expect(flash[:notice]).to eq("Changes saved!")
            end
          end
        end
      end

      context "when bundle is not eligible for installment plans" do
        let!(:bundle_product) { create(:bundle_product, bundle: bundle, product: commission_product) }

        it "does not create an installment plan" do
          params = bundle_params.merge(installment_plan: { number_of_installments: 3 })

          expect { put :update, params: params }
            .not_to change { ProductInstallmentPlan.count }

          expect(bundle.reload.installment_plan).to be_nil
          expect(response).to redirect_to(edit_bundle_product_path(bundle.external_id))
          expect(flash[:alert]).to include("Installment plan is not available for the bundled product")
        end
      end

      context "when bundle has customizable price" do
        before { bundle.update!(customizable_price: true) }

        it "does not create an installment plan" do
          params = bundle_params.merge(
            customizable_price: true,
            installment_plan: { number_of_installments: 3 }
          )

          expect { put :update, params: params }
            .not_to change { ProductInstallmentPlan.count }

          expect(bundle.reload.installment_plan).to be_nil
          expect(response).to redirect_to(edit_bundle_product_path(bundle.external_id))
          expect(flash[:alert]).to include("Installment plans are not available for \"pay what you want\" pricing")
        end
      end
    end

    context "when seller_refund_policy_disabled_for_all feature flag is set to true" do
      before do
        Feature.activate(:seller_refund_policy_disabled_for_all)
      end

      it "updates the bundle refund policy" do
        put :update, params: bundle_params
        bundle.reload
        expect(bundle.product_refund_policy_enabled).to be(true)
        expect(bundle.product_refund_policy.title).to eq("30-day money back guarantee")
        expect(bundle.product_refund_policy.fine_print).to eq("I really hate being small")
        expect(response).to redirect_to(edit_bundle_product_path(bundle.external_id))
        expect(flash[:notice]).to eq("Changes saved!")
      end
    end

    context "when seller refund policy is set to false" do
      before do
        seller.update!(refund_policy_enabled: false)
      end

      it "updates the bundle refund policy" do
        put :update, params: bundle_params
        bundle.reload
        expect(bundle.product_refund_policy_enabled).to be(true)
        expect(bundle.product_refund_policy.title).to eq("30-day money back guarantee")
        expect(bundle.product_refund_policy.fine_print).to eq("I really hate being small")
        expect(response).to redirect_to(edit_bundle_product_path(bundle.external_id))
        expect(flash[:notice]).to eq("Changes saved!")
      end

      context "with bundle refund policy enabled" do
        before do
          bundle.update!(product_refund_policy_enabled: true)
        end

        it "disables the product refund policy" do
          bundle_params[:product_refund_policy_enabled] = false
          put :update, params: bundle_params
          bundle.reload
          expect(bundle.product_refund_policy_enabled).to be(false)
          expect(bundle.product_refund_policy).to be_nil
          expect(response).to redirect_to(edit_bundle_product_path(bundle.external_id))
          expect(flash[:notice]).to eq("Changes saved!")
        end
      end
    end


    context "when there is a validation error" do
      it "returns the error message" do
        expect do
          put :update, params: {
            bundle_id: bundle.external_id,
            custom_permalink: "*",
          }
        end.to_not change { bundle.reload.custom_permalink }

        expect(response).to redirect_to(edit_bundle_product_path(bundle.external_id))
        expect(flash[:alert]).to eq("Custom permalink is invalid")
      end
    end

    context "when the bundle doesn't exist" do
      it "returns 404" do
        expect { put :update, params: { bundle_id: "" } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "product is a call" do
      let(:product) { create(:call_product) }

      it "returns 404" do
        expect { put :update, params: { bundle_id: product.external_id } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "product is membership" do
      let(:product) { create(:membership_product) }

      it "returns 404" do
        expect { put :update, params: { bundle_id: product.external_id } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "product has variants" do
      let(:product) { create(:product_with_digital_versions) }

      it "returns 404" do
        expect { put :update, params: { bundle_id: product.external_id } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end
