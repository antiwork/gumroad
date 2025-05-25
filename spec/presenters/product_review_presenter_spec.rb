# frozen_string_literal: true

describe ProductReviewPresenter do
  include ActionView::Helpers::DateHelper

  let(:product_review) { create(:product_review) }

  describe "#product_review_props" do
    it "returns the correct props" do
      expect(described_class.new(product_review).product_review_props).to eq(
        {
          id: product_review.external_id,
          message: product_review.message,
          rater: {
            avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"),
            name: "Anonymous"
          },
          rating: product_review.rating,
          purchase_id: product_review.purchase.external_id,
          is_new: true,
          response: nil,
          video: nil
        }
      )
    end

    context "product review is more than a month old" do
      before { product_review.update!(created_at: 2.months.ago) }

      it "returns is_new as false" do
        expect(described_class.new(product_review).product_review_props[:is_new]).to be false
      end
    end

    context "product review has a response" do
      let!(:product_review_response) { create(:product_review_response, product_review:) }

      it "returns the correct props" do
        expect(described_class.new(product_review).product_review_props[:response]).to eq(
          {
            message: product_review_response.message,
          }
        )
      end
    end

    context "product review is not associated with an account" do
      before { product_review.purchase.update!(full_name: "Purchaser") }
      it "uses the purchase's full name" do
        expect(described_class.new(product_review).product_review_props[:rater]).to eq(
          {
            avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"),
            name: "Purchaser",
          }
        )
      end
    end

    context "product review is associated with an account" do
      let(:purchaser) { create(:user, :with_avatar, name: "Reviewer") }

      before do
        product_review.purchase.update!(purchaser:)
      end

      it "uses the account's avatar and name" do
        expect(described_class.new(product_review).product_review_props[:rater]).to eq(
          {
            avatar_url: purchaser.avatar_variant.url,
            name: "Reviewer",
          }
        )
      end

      context "account's name is blank" do
        before { purchaser.update!(name: nil) }

        it "uses 'Anonymous'" do
          expect(described_class.new(product_review).product_review_props[:rater][:name]).to eq("Anonymous")
        end

        context "purchase's full name is present" do
          before { product_review.purchase.update!(full_name: "Purchaser") }

          it "uses the purchase's full name" do
            expect(described_class.new(product_review).product_review_props[:rater][:name]).to eq("Purchaser")
          end
        end
      end
    end

    context "product review has videos" do
      let(:video) { create(:product_review_video, product_review:) }

      it "only includes the approved video" do
        video.pending_review!
        product_review.reload
        expect(described_class.new(product_review).product_review_props[:video]).to be nil

        video.approved!
        product_review.reload
        expect(described_class.new(product_review).product_review_props[:video]).to eq(
          {
            id: video.external_id,
            thumbnail_url: video.video_file.thumbnail_url,
          }
        )
      end
    end
  end

  describe "#review_form_props" do
    it "returns the correct props" do
      expect(described_class.new(product_review).review_form_props).to eq(
        {
          message: product_review.message,
          rating: product_review.rating,
          video: nil
        }
      )
    end

    context "product review has a rejected video" do
      let!(:video) { create(:product_review_video, :rejected, product_review:) }

      it "does not include the video props" do
        expect(described_class.new(product_review).review_form_props[:video]).to be nil
      end
    end

    context "product review has a pending video" do
      let!(:video) { create(:product_review_video, :pending_review, product_review:) }

      it "includes the video props" do
        expect(described_class.new(product_review).review_form_props[:video]).to eq(
          {
            id: video.external_id,
            thumbnail_url: video.video_file.thumbnail_url,
          }
        )
      end
    end

    context "product review has an approved video" do
      let!(:video) { create(:product_review_video, :approved, product_review:) }

      it "includes the video props" do
        expect(described_class.new(product_review).review_form_props[:video]).to eq(
          {
            id: video.external_id,
            thumbnail_url: video.video_file.thumbnail_url,
          }
        )
      end
    end
  end
end
