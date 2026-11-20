# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe LinksController, type: :controller, inertia: true do
  let(:seller) { create(:named_seller) }

  before do
    sign_in seller
    allow(controller).to receive(:current_seller).and_return(seller)
  end

  describe "GET edit" do
    context "when a live product's custom permalink is a soft-deleted sibling's unique permalink" do
      let!(:deleted_sibling) { create(:product, user: seller, unique_permalink: "extkgs", deleted_at: 1.day.ago) }
      let!(:product) { create(:product, user: seller, custom_permalink: "extkgs") }

      it "boots the editor on the live product with its true unique permalink" do
        get :edit, params: { id: "extkgs" }

        expect(response).to be_successful
        expect(inertia.props[:unique_permalink]).to eq(product.unique_permalink)
      end
    end

    it "resolves a live product by its unique permalink" do
      product = create(:product, user: seller)

      get :edit, params: { id: product.unique_permalink }

      expect(response).to be_successful
      expect(inertia.props[:unique_permalink]).to eq(product.unique_permalink)
    end

    it "404s for a stale deleted-product URL" do
      deleted = create(:product, user: seller, deleted_at: 1.day.ago)

      expect { get :edit, params: { id: deleted.unique_permalink } }.to raise_error(ActionController::RoutingError)
    end

    it "does not resolve another seller's product by its custom permalink" do
      create(:product, user: create(:user), custom_permalink: "shared-slug")

      expect { get :edit, params: { id: "shared-slug" } }.to raise_error(ActionController::RoutingError)
    end

    it "opens the current seller's product when another seller uses the same custom permalink" do
      create(:product, user: create(:user), custom_permalink: "shared-slug")
      product = create(:product, user: seller, custom_permalink: "shared-slug")

      get :edit, params: { id: "shared-slug" }

      expect(response).to be_successful
      expect(inertia.props[:unique_permalink]).to eq(product.unique_permalink)
    end
  end
end
