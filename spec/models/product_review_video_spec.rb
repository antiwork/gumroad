# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProductReviewVideo, type: :model do
  describe "approval status transitions" do
    let(:product_review) { create(:product_review) }
    let!(:pending_video) { create(:product_review_video, :pending_review, product_review:) }
    let!(:approved_video) { create(:product_review_video, :approved, product_review:) }
    let!(:rejected_video) { create(:product_review_video, :rejected, product_review:) }


    it "marks other videos of the same status as deleted" do
      new_video = create(:product_review_video, product_review:)

      expect { new_video.pending_review! }
        .to change { pending_video.reload.deleted? }
        .from(false).to(true)

      expect { new_video.approved! }
        .to change { approved_video.reload.deleted? }
        .from(false).to(true)

      expect { new_video.rejected! }
        .to change { rejected_video.reload.deleted? }
        .from(false).to(true)
    end
  end
end
