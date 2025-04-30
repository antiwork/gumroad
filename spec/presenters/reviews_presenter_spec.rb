# frozen_string_literal: true

require "spec_helper"

describe ReviewsPresenter do
  describe "#reviews_props" do
    let(:user) { create(:user) }
    let(:presenter) { described_class.new(user) }
    let(:seller) { create(:user, name: "Seller") }
    let!(:reviews) do
      build_list(:product_review, 3) do |review, i|
        review.purchase.purchaser = user
        review.message = if i > 0 then "Message #{i}" else nil end
        review.update!(rating: i + 1)
        review.link.update!(user: seller)
      end
    end
    let!(:thumbnail) { create(:thumbnail, product: reviews.first.link) }
    let!(:product1) { create(:product, user: seller, name: "Product 1") }
    let!(:product2) { create(:product, user: seller, name: "Product 2") }
    let!(:product3) { create(:product, name: "Product 3") }
    let!(:purchase1) { create(:purchase, purchaser: user, link: product1) }
    let!(:purchase2) { create(:purchase, purchaser: user, link: product2) }
    let!(:purchase3) { create(:purchase, purchaser: user, link: product3, created_at: 3.years.ago) }
    let!(:thumbnail1) { create(:thumbnail, product: product1) }

    before { purchase3.seller.update!(disable_reviews_after_year: true) }

    it "returns props for the reviews page" do
      expect(presenter.reviews_props).to eq(
        {
          reviews: [
            ProductReviewPresenter.new(reviews.first).review_form_props.merge(
              id: reviews.first.external_id,
              purchase_id: reviews.first.purchase.external_id,
              purchase_email_digest: reviews.first.purchase.email_digest,
              product: {
                name: reviews.first.link.name,
                url: reviews.first.link.long_url(recommended_by: "library"),
                permalink: reviews.first.link.unique_permalink,
                thumbnail_url: thumbnail.url,
                native_type: "digital",
                seller: {
                  name: "Seller",
                  url: seller.profile_url,
                }
              }
            ),
            ProductReviewPresenter.new(reviews.second).review_form_props.merge(
              id: reviews.second.external_id,
              purchase_id: reviews.second.purchase.external_id,
              purchase_email_digest: reviews.second.purchase.email_digest,
              product: {
                name: reviews.second.link.name,
                url: reviews.second.link.long_url(recommended_by: "library"),
                permalink: reviews.second.link.unique_permalink,
                thumbnail_url: nil,
                native_type: "digital",
                seller: {
                  name: "Seller",
                  url: seller.profile_url,
                }
              }
            ),
            ProductReviewPresenter.new(reviews.third).review_form_props.merge(
              id: reviews.third.external_id,
              purchase_id: reviews.third.purchase.external_id,
              purchase_email_digest: reviews.third.purchase.email_digest,
              product: {
                name: reviews.third.link.name,
                url: reviews.third.link.long_url(recommended_by: "library"),
                permalink: reviews.third.link.unique_permalink,
                thumbnail_url: nil,
                native_type: "digital",
                seller: {
                  name: "Seller",
                  url: seller.profile_url,
                }
              }
            )
          ],
          purchases: [
            {
              id: purchase1.external_id,
              email_digest: purchase1.email_digest,
              product: {
                name: product1.name,
                url: product1.long_url(recommended_by: "library"),
                permalink: product1.unique_permalink,
                thumbnail_url: thumbnail1.url,
                native_type: "digital",
                seller: {
                  name: "Seller",
                  url: seller.profile_url,
                }
              }
            },
            {
              id: purchase2.external_id,
              email_digest: purchase2.email_digest,
              product: {
                name: product2.name,
                url: product2.long_url(recommended_by: "library"),
                permalink: product2.unique_permalink,
                thumbnail_url: nil,
                native_type: "digital",
                seller: {
                  name: "Seller",
                  url: seller.profile_url,
                }
              }
            }
          ],
        }
      )
    end
  end
end
