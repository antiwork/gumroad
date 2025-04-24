# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProductReviewVideoPresenter do
  let(:seller) { create(:user) }
  let(:another_seller) { create(:user) }

  let(:link) { create(:product, user: seller) }
  let(:purchase) { create(:purchase, seller:, link:) }
  let(:product_review) { create(:product_review, purchase:) }

  let(:video) { create(:product_review_video, :approved, product_review:) }

  let(:pundit_user) { SellerContext.new(user: seller, seller:) }

  describe "#props" do
    it "returns the correct props" do
      presenter = described_class.new(video)

      expect(presenter.props(pundit_user:)).to match(
        id: video.external_id,
        approval_status: video.approval_status,
        thumbnail_url: video.video_file.thumbnail_url,
        can_approve: true,
        can_reject: true,
      )
    end

    describe "can_approve" do
      context "when the user has approval permission" do
        let(:pundit_user) { SellerContext.new(user: seller, seller:) }

        it "returns true" do
          presenter = described_class.new(video)
          expect(presenter.props(pundit_user:)[:can_approve]).to eq(true)
        end
      end

      context "when the user does not have approval permission" do
        let(:pundit_user) { SellerContext.new(user: another_seller, seller: another_seller) }

        it "returns false" do
          presenter = described_class.new(video)
          expect(presenter.props(pundit_user:)[:can_approve]).to eq(false)
        end
      end
    end

    describe "can_reject" do
      context "when the user has rejection permission" do
        let(:pundit_user) { SellerContext.new(user: seller, seller:) }

        it "returns true" do
          presenter = described_class.new(video)
          expect(presenter.props(pundit_user:)[:can_reject]).to eq(true)
        end
      end

      context "when the user does not have rejection permission" do
        let(:pundit_user) { SellerContext.new(user: another_seller, seller: another_seller) }

        it "returns false" do
          presenter = described_class.new(video)
          expect(presenter.props(pundit_user:)[:can_reject]).to eq(false)
        end
      end
    end
  end
end
