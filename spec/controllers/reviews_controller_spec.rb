# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe ReviewsController, type: :controller, inertia: true do
  let(:user) { create(:user) }

  describe "GET index" do
    before do
      Feature.activate(:reviews_page)
      sign_in(user)
    end

    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { ProductReview }
    end

    it "renders the Inertia component with correct props" do
      product = create(:product, price_cents: 0)
      purchase_with_review = create(:free_purchase, :with_review, link: product)
      purchase_with_review.update!(purchaser: user, email: user.email)
      review = purchase_with_review.product_review

      product_without_review = create(:product, price_cents: 0)
      purchase_without_review = create(:free_purchase, link: product_without_review)
      purchase_without_review.update!(purchaser: user, email: user.email)

      expect(ReviewsPresenter).to receive(:new).with(user).and_call_original

      get :index

      expect(response).to be_successful
      expect(inertia.component).to eq("Reviews/Index")

      expect(inertia.props[:reviews]).to be_an(Array)
      review_props = inertia.props[:reviews].first
      expect(review_props).to include(
        id: review.external_id,
        rating: review.rating,
        message: review.message,
        purchase_id: ObfuscateIds.encrypt(review.purchase_id),
        purchase_email_digest: purchase_with_review.email_digest
      )
      expect(review_props).to have_key(:video)
      expect(review_props[:video]).to be_in([nil, a_hash_including(:id, :thumbnail_url)])

      expect(review_props[:product]).to include(
        name: product.name,
        url: product.long_url(recommended_by: "library"),
        permalink: product.unique_permalink,
        thumbnail_url: product.thumbnail_alive&.url,
        native_type: product.native_type
      )
      expect(review_props[:product][:seller]).to include(
        name: product.user.display_name,
        url: product.user.profile_url
      )

      expect(inertia.props[:purchases]).to be_an(Array)
      purchase_props = inertia.props[:purchases].find { |p| p[:id] == purchase_without_review.external_id }
      expect(purchase_props).to be_present
      expect(purchase_props).to include(
        id: purchase_without_review.external_id,
        email_digest: purchase_without_review.email_digest
      )
      expect(purchase_props[:product]).to include(
        name: product_without_review.name,
        url: product_without_review.long_url(recommended_by: "library"),
        permalink: product_without_review.unique_permalink,
        thumbnail_url: product_without_review.thumbnail_alive&.url,
        native_type: product_without_review.native_type
      )
      expect(purchase_props[:product][:seller]).to include(
        name: product_without_review.user.display_name,
        url: product_without_review.user.profile_url
      )

      expect(inertia.props[:following_wishlists_enabled]).to be_in([true, false])
    end
  end
end
