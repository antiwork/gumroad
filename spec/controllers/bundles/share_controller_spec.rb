# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe Bundles::ShareController, inertia: true do
  let(:seller) { create(:named_seller, :eligible_for_service_products) }
  let(:bundle) { create(:product, :bundle, user: seller, price_cents: 2000, draft: false) }

  include_context "with user signed in as admin for seller"

  describe "GET edit" do
    context "when bundle is published" do
      it "renders the Bundles/Share/Edit Inertia component with expected props" do
        get :edit, params: { bundle_id: bundle.external_id }
        expect(response).to be_successful
        expect(inertia.component).to eq("Bundles/Share/Edit")
        expect(controller.send(:page_title)).to eq(bundle.name)

        expect(inertia.props[:id]).to eq(bundle.external_id)
        expect(inertia.props[:unique_permalink]).to eq(bundle.unique_permalink)
        expect(inertia.props[:currency_type]).to eq(bundle.price_currency_type)
        expect(inertia.props[:bundle][:name]).to eq(bundle.name)
        expect(inertia.props[:bundle][:products]).to be_an(Array)
        expect(inertia.props[:taxonomies]).to be_an(Array)
        expect(inertia.props[:profile_sections]).to be_an(Array)
      end
    end

    context "when bundle is unpublished" do
      let(:bundle) { create(:product, :bundle, user: seller, price_cents: 2000, draft: true) }

      it "redirects to content page with alert" do
        get :edit, params: { bundle_id: bundle.external_id }
        expect(response).to redirect_to(edit_bundle_content_path(bundle.external_id))
        expect(flash[:alert]).to eq("Not yet! You've got to publish your awesome product before you can share it with your audience and the world.")
      end
    end
  end

  describe "PUT update" do
    let(:profile_section1) { create(:seller_profile_products_section, seller:, shown_products: [bundle.id]) }
    let(:profile_section2) { create(:seller_profile_products_section, seller:) }
    let!(:taxonomy) { Taxonomy.create!(slug: "test-taxonomy") }

    it_behaves_like "authorize called for action", :put, :update do
      let(:policy_klass) { LinkPolicy }
      let(:record) { bundle }
      let(:request_params) { { bundle_id: bundle.external_id } }
    end

    it "updates section_ids and redirects" do
      expect do
        put :update, params: {
          bundle_id: bundle.external_id,
          section_ids: [profile_section2.external_id]
        }
        bundle.reload
      end.to change { profile_section1.reload.shown_products }.from([bundle.id]).to([])
      .and change { profile_section2.reload.shown_products }.from([]).to([bundle.id])

      expect(response).to redirect_to(edit_bundle_share_path(bundle.external_id))
      expect(flash[:notice]).to eq("Changes saved!")
    end

    it "updates discover attributes" do
      expect do
        put :update, params: {
          bundle_id: bundle.external_id,
          taxonomy_id: taxonomy.id,
          tags: ["tag1", "tag2"],
          display_product_reviews: false,
          is_adult: true
        }
        bundle.reload
      end.to change { bundle.taxonomy_id }.from(nil).to(taxonomy.id)
      .and change { bundle.tags.pluck(:name) }.from([]).to(["tag1", "tag2"])
      .and change { bundle.display_product_reviews }.from(true).to(false)
      .and change { bundle.is_adult }.from(false).to(true)

      expect(response).to redirect_to(edit_bundle_share_path(bundle.external_id))
      expect(flash[:notice]).to eq("Changes saved!")
    end

    context "when unpublishing" do
      it "unpublishes and redirects to content page" do
        expect do
          put :update, params: {
            bundle_id: bundle.external_id,
            unpublish: true
          }
          bundle.reload
        end.to change { bundle.published? }.from(true).to(false)

        expect(response).to redirect_to(edit_bundle_content_path(bundle.external_id))
        expect(flash[:notice]).to eq("Unpublished!")
      end
    end
  end
end
