# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe Bundles::ContentController, inertia: true do
  let(:seller) { create(:named_seller, :eligible_for_service_products) }
  let(:bundle) { create(:product, :bundle, user: seller, price_cents: 2000) }

  include_context "with user signed in as admin for seller"

  describe "GET edit" do
    it "renders the Bundles/Content/Edit Inertia component with expected props" do
      get :edit, params: { bundle_id: bundle.external_id }
      expect(response).to be_successful
      expect(inertia.component).to eq("Bundles/Content/Edit")
      expect(controller.send(:page_title)).to eq(bundle.name)

      expect(inertia.props[:id]).to eq(bundle.external_id)
      expect(inertia.props[:unique_permalink]).to eq(bundle.unique_permalink)
      expect(inertia.props[:bundle][:name]).to eq(bundle.name)
      expect(inertia.props[:bundle][:price_cents]).to eq(bundle.price_cents)
      expect(inertia.props[:bundle][:products]).to be_an(Array)
      expect(inertia.props[:products_count]).to be_a(Integer)
    end
  end

  describe "PUT update" do
    let(:product) { create(:product, user: seller) }
    let(:versioned_product) { create(:product_with_digital_versions, user: seller) }
    let!(:purchase) { create(:purchase, link: bundle) }

    it_behaves_like "authorize called for action", :put, :update do
      let(:policy_klass) { LinkPolicy }
      let(:record) { bundle }
      let(:request_params) { { bundle_id: bundle.external_id } }
    end

    before { index_model_records(Purchase) }

    it "updates bundle products and redirects" do
      expect do
        put :update, params: {
          bundle_id: bundle.external_id,
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
        bundle.reload
      end.to change { bundle.has_outdated_purchases }.from(false).to(true)

      expect(response).to redirect_to(edit_bundle_content_path(bundle.external_id))
      expect(flash[:notice]).to eq("Changes saved!")

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

    it "keeps a supplied redirect on the Gumroad host" do
      put :update, params: {
        bundle_id: bundle.external_id,
        redirect_to: "https://evil.example/phish",
        products: [{ product_id: bundle.bundle_products.first.product.external_id, quantity: 1 }]
      }

      expect(response).to redirect_to("/phish")
    end

    context "adding a call to a bundle" do
      let(:call_product) { create(:call_product, user: seller) }

      it "does not make any changes to the bundle and returns an error" do
        expect do
          put :update, params: {
            bundle_id: bundle.external_id,
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

        expect(response).to redirect_to(edit_bundle_content_path(bundle.external_id))
        expect(flash[:alert]).to eq("Validation failed: A call product cannot be added to a bundle")
      end
    end

    context "when adding a product with a single alive variant and no variant_id" do
      let(:product_with_single_alive_variant) { create(:product_with_digital_versions, user: seller) }

      before do
        product_with_single_alive_variant.alive_variants.last.mark_deleted!
      end

      it "updates bundle products successfully" do
        put :update, params: {
          bundle_id: bundle.external_id,
          products: [
            {
              product_id: product_with_single_alive_variant.external_id,
              quantity: 1,
            }
          ]
        }

        expect(response).to redirect_to(edit_bundle_content_path(bundle.external_id))
        expect(flash[:notice]).to eq("Changes saved!")

        updated_bundle_product = bundle.reload.bundle_products.alive.find_by(product_id: product_with_single_alive_variant.id)
        expect(updated_bundle_product).to be_present
        expect(updated_bundle_product.variant).to be_nil
      end
    end

    context "when publishing" do
      let!(:draft_bundle) { create(:product, :bundle, user: seller, price_cents: 2000, draft: true) }
      let(:publish_params) do
        {
          bundle_id: draft_bundle.external_id,
          publish: "true",
          products: [{ product_id: product.external_id, quantity: 1 }]
        }
      end
      let(:passed_result) { ContentModeration::ModerateRecordService::CheckResult.new(passed: true, reasons: []) }

      def record_statements_and_moderation
        events = []
        allow(ContentModeration::ModerateRecordService).to receive(:check) do
          events << :moderation
          passed_result
        end
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          events << (payload[:sql].include?("FROM `users`") ? :seller_lock : :bundle_lock) if payload[:sql].include?("FOR UPDATE")
        end
        yield
        events
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      it "moderates once, before the seller and bundle locks are taken" do
        events = record_statements_and_moderation { put :update, params: publish_params }

        expect(response).to redirect_to(edit_bundle_share_path(draft_bundle.external_id))
        expect(draft_bundle.reload).to be_published
        expect(events.count(:moderation)).to eq(1)
        expect(events.first).to eq(:moderation)
        expect(events).to include(:seller_lock, :bundle_lock)
      end

      it "leaves the bundle unpublished and unchanged when moderation blocks publishing" do
        allow(ContentModeration::ModerateRecordService).to receive(:check)
          .and_return(ContentModeration::ModerateRecordService::CheckResult.new(passed: false, reasons: ["Matched blocked word: forbidden"]))

        expect do
          put :update, params: publish_params
        end.not_to change { draft_bundle.reload.bundle_products.count }

        expect(draft_bundle).not_to be_published
        expect(response).to redirect_to(edit_bundle_content_path(draft_bundle.external_id))
        expect(flash[:alert]).to be_present
      end
    end

    context "when publishing a draft whose bundle products arrive in the same request" do
      let(:flagged_result) do
        ContentModeration::Strategies::PromptStrategy::Result.new(
          status: "flagged",
          reasoning: ["spam: reads like a sales pitch and lacks coherent prose"],
          audit_reasoning: []
        )
      end
      let(:compliant_result) { Struct.new(:status, :reasoning, keyword_init: true).new(status: "compliant", reasoning: []) }
      let!(:converting_draft) { create(:product, user: seller, price_cents: 2000, draft: true, name: "Bundle", description: "Everything you need") }
      let!(:empty_bundle_draft) { create(:product, :bundle, user: seller, price_cents: 2000, draft: true, name: "Bundle", description: "Everything you need") }

      before do
        Feature.activate(:content_moderation)
        allow(ContentModeration::Strategies::BlocklistStrategy).to receive(:new).and_return(
          instance_double(ContentModeration::Strategies::BlocklistStrategy, perform: compliant_result)
        )
        allow(ContentModeration::Strategies::ClassifierStrategy).to receive(:new).and_return(
          instance_double(ContentModeration::Strategies::ClassifierStrategy, perform: compliant_result)
        )
        allow(ContentModeration::Strategies::PromptStrategy).to receive(:new).and_return(
          instance_double(ContentModeration::Strategies::PromptStrategy, perform: flagged_result)
        )
      end

      it "treats an empty draft converted and published with products as a substantive bundle" do
        put :update, params: { bundle_id: converting_draft.external_id, publish: "true", products: [{ product_id: product.external_id, quantity: 1 }] }

        expect(response).to redirect_to(edit_bundle_share_path(converting_draft.external_id))
        expect(converting_draft.reload).to be_published
        expect(converting_draft.is_bundle).to eq(true)
        expect(converting_draft.bundle_products.alive.count).to eq(1)
        expect(ContentModeration::Strategies::PromptStrategy).to have_received(:new)
          .with(hash_including(check_off_platform_fulfillment: false)).once
      end

      it "treats an empty draft bundle published with products as substantive" do
        empty_bundle_draft.bundle_products.each(&:mark_deleted!)

        put :update, params: { bundle_id: empty_bundle_draft.external_id, publish: "true", products: [{ product_id: product.external_id, quantity: 1 }] }

        expect(empty_bundle_draft.reload).to be_published
        expect(empty_bundle_draft.bundle_products.alive.pluck(:product_id)).to eq([product.id])
      end

      it "blocks the publish and persists nothing when the final products are empty" do
        expect do
          put :update, params: { bundle_id: converting_draft.external_id, publish: "true" }
        end.not_to change { BundleProduct.count }

        expect(response).to redirect_to(edit_bundle_content_path(converting_draft.external_id))
        expect(flash[:alert]).to be_present
        converting_draft.reload
        expect(converting_draft).not_to be_published
        expect(converting_draft.is_bundle).to eq(false)
      end

      it "blocks publishing when the request removes every product of a persisted bundle" do
        persisted_count = empty_bundle_draft.bundle_products.alive.count
        expect(persisted_count).to be_positive

        put :update, params: { bundle_id: empty_bundle_draft.external_id, publish: "true" }

        expect(flash[:alert]).to be_present
        expect(empty_bundle_draft.reload).not_to be_published
        expect(empty_bundle_draft.bundle_products.alive.count).to eq(persisted_count)
      end
    end

    context "when there is a validation error" do
      let(:published_bundle) do
        bundle = create(:product, :bundle, user: seller, price_cents: 2000, draft: false)
        create(:bundle_product, bundle: bundle, product: product)
        bundle.reload
      end

      it "returns the error message when published bundle has no products" do
        put :update, params: {
          bundle_id: published_bundle.external_id,
          products: []
        }

        expect(response).to redirect_to(edit_bundle_content_path(published_bundle.external_id))
        expect(flash[:alert]).to eq("Bundles must have at least one product.")
      end
    end
  end

  describe "PUT update_purchases_content" do
    it "updates the purchases content and redirects" do
      bundle.update!(has_outdated_purchases: true)
      put :update_purchases_content, params: { bundle_id: bundle.external_id }
      expect(bundle.reload.has_outdated_purchases).to be(false)
      expect(response).to redirect_to(edit_bundle_content_path(bundle.external_id))
      expect(flash[:notice]).to eq("Queued an update to the content of all outdated purchases.")
      expect(UpdateBundlePurchasesContentJob).to have_enqueued_sidekiq_job(bundle.id)
    end
  end
end
