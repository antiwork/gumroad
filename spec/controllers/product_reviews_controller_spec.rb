# frozen_string_literal: true

require "spec_helper"

describe ProductReviewsController do
  let(:product) { create(:product) }
  let(:purchaser) { create(:user) }
  let(:purchase) { create(:purchase, link: product, purchaser: purchaser, created_at: 2.years.ago) }
  let(:valid_params) do
    {
      link_id: product.unique_permalink,
      purchase_id: purchase.external_id,
      purchase_email_digest: purchase.email_digest,
      rating: 4,
      message: "This is my review"
    }
  end

  describe "#set" do
    context "with valid params" do
      it "creates a product review" do
        put :set, params: valid_params

        expect(response.parsed_body["success"]).to eq(true)
        purchase.reload
        expect(purchase.product_review.rating).to eq(4)
        expect(purchase.product_review.message).to eq("This is my review")
      end

      it "updates an existing review" do
        review = create(:product_review, purchase: purchase, rating: 3)
        put :set, params: valid_params.merge(rating: 2)

        expect(response.parsed_body["success"]).to eq(true)
        review.reload
        expect(review.rating).to eq(2)
      end

      it "allows saving the same rating" do
        put :set, params: valid_params
        expect(response.parsed_body["success"]).to eq(true)
        expect(purchase.reload.product_review.rating).to eq(4)

        put :set, params: valid_params
        expect(response.parsed_body["success"]).to eq(true)
        expect(purchase.reload.product_review.rating).to eq(4)
      end

      context "video review" do
        let(:video_url) { "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/video.mp4" }
        let(:blob) do
          ActiveStorage::Blob.create_and_upload!(
            io: fixture_file_upload("test-small.jpg"),
            filename: "test-small.jpg",
            content_type: "image/jpeg"
          )
        end

        it "allows creating and destroying a video review" do
          put :set, params: valid_params.merge(
            video_options: {
              create: {
                url: video_url,
                thumbnail_signed_id: blob.signed_id
              }
            }
          )

          expect(response.parsed_body["success"]).to eq(true)
          review = purchase.reload.product_review
          expect(review.videos.count).to eq(1)

          video = review.videos.first
          expect(video.video_file.url).to eq(video_url)
          expect(video.video_file.thumbnail.signed_id).to eq(blob.signed_id)

          put :set, params: valid_params.merge(
            video_options: {
              destroy: { id: video.external_id }
            }
          )

          expect(response.parsed_body["success"]).to eq(true)
          expect(video.reload.deleted?).to eq(true)
        end
      end
    end

    context "with invalid params" do
      it "rejects invalid email digest" do
        put :set, params: valid_params.merge(purchase_email_digest: "invalid_digest")

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("Sorry, you are not authorized to review this product.")
        expect(purchase.reload.product_review).to be_nil
      end

      it "rejects missing email digest" do
        put :set, params: valid_params.except(:purchase_email_digest)

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("Sorry, you are not authorized to review this product.")
        expect(purchase.reload.product_review).to be_nil
      end

      it "rejects invalid rating" do
        put :set, params: valid_params.merge(rating: 6)

        expect(response.parsed_body["success"]).to eq(false)
        expect(purchase.reload.product_review).to be_nil
      end

      it "rejects mismatched purchase and product" do
        other_purchase = create(:purchase, purchaser: purchaser)
        put :set, params: valid_params.merge(purchase_id: other_purchase.external_id)

        expect(response.parsed_body["success"]).to eq(false)
        expect(purchase.reload.product_review).to be_nil
      end

      it "rejects ineligible purchases" do
        purchase.update!(stripe_refunded: true)
        put :set, params: valid_params

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("Sorry, something went wrong.")
        expect(purchase.reload.product_review).to be_nil
      end
    end

    context "when seller has reviews disabled after 1 year" do
      before { product.user.update!(disable_reviews_after_year: true) }

      it "rejects reviews for old purchases" do
        put :set, params: valid_params

        expect(response.parsed_body["success"]).to eq(false)
        expect(purchase.reload.product_review).to be_nil
      end

      it "rejects updates to old reviews" do
        review = create(:product_review, purchase: purchase, rating: 2)
        put :set, params: valid_params

        expect(response.parsed_body["success"]).to eq(false)
        expect(review.reload.rating).to eq(2)
      end
    end
  end

  describe "#index" do
    let(:product) { create(:product, display_product_reviews: true) }
    let!(:reviews) do
      build_list(:product_review, 3, purchase: nil) do |review, i|
        review.update!(purchase: create(:purchase, link: product), link: product, rating: i + 1)
        review.reload
      end
    end
    let!(:deleted_review) { create(:product_review, purchase: create(:purchase, link: product), deleted_at: Time.current) }
    let!(:non_written_review) { create(:product_review, message: nil, purchase: create(:purchase, link: product)) }

    before do
      stub_const("ProductReviewsController::PER_PAGE", 2)
    end

    context "when product doesn't exist" do
      it "returns not found" do
        get :index, params: { product_id: "" }
        expect(response).to have_http_status(:not_found)
      end
    end

    context "when product reviews are hidden" do
      before { product.update!(display_product_reviews: false) }

      it "returns forbidden" do
        get :index, params: { product_id: product.external_id }
        expect(response).to have_http_status(:forbidden)
      end

      it "allows product owner to view reviews" do
        sign_in product.user
        get :index, params: { product_id: product.external_id }
        expect(response).to be_successful
      end
    end

    it "returns paginated product reviews" do
      get :index, params: { product_id: product.external_id }

      expect(response).to be_successful
      expect(response.parsed_body["pagination"]).to eq({ "page" => 1, "pages" => 2 })
      expect(response.parsed_body["reviews"].map(&:deep_symbolize_keys)).to eq(
        reviews.reverse.first(2).map { ProductReviewPresenter.new(_1).product_review_props }
      )
    end
  end

  describe "#show" do
    let(:product) { create(:product, display_product_reviews: true) }
    let(:review) { create(:product_review, purchase: create(:purchase, link: product), link: product, rating: 5, message: "Great product!") }
    let(:deleted_review) { create(:product_review, deleted_at: Time.current, purchase: create(:purchase, link: product), link: product) }
    let(:empty_message_review) { create(:product_review, message: nil, purchase: create(:purchase, link: product), link: product) }

    context "when review doesn't exist" do
      it "returns not found" do
        expect { get :show, params: { id: "nonexistent-id" } }
          .to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "when review is deleted" do
      it "returns not found" do
        expect { get :show, params: { id: deleted_review.external_id } }
          .to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "when the review has no message nor approved videos" do
      let!(:pending_video) do
        create(:product_review_video, :pending_review, product_review: empty_message_review)
      end

      it "returns not found" do
        expect { get :show, params: { id: empty_message_review.external_id } }
          .to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "when the review only has an approved video" do
      let!(:approved_video) do
        create(:product_review_video, :approved, product_review: empty_message_review)
      end

      it "returns the product review" do
        get :show, params: { id: empty_message_review.external_id }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["review"]).to match(
          ProductReviewPresenter.new(empty_message_review).product_review_props
        )
      end
    end

    context "when product reviews are hidden" do
      before { product.update!(display_product_reviews: false) }

      it "returns forbidden" do
        get :show, params: { id: review.external_id }
        expect(response).to have_http_status(:forbidden)
      end

      it "allows product owner to view the review" do
        sign_in product.user
        get :show, params: { id: review.external_id }
        expect(response).to be_successful
      end
    end

    it "returns the product review" do
      get :show, params: { id: review.external_id }

      expect(response).to be_successful
      expect(response.parsed_body["review"].deep_symbolize_keys).to eq(
        ProductReviewPresenter.new(review).product_review_props
      )
    end
  end
end
