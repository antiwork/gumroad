# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProductReview::UpdateService do
  let(:product_review) { create(:product_review, rating: 3, message: "Original message") }

  describe "#update" do
    it "updates the product review with the new rating and message" do
      described_class.new(product_review, rating: 5, message: "Updated message").update

      product_review.reload

      expect(product_review.rating).to eq(5)
      expect(product_review.message).to eq("Updated message")
    end
  end
end
