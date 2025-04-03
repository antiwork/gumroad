# frozen_string_literal: true

require "spec_helper"

describe ProductReviewResponse do
  let(:product_review) { create(:product_review) }

  describe "validations" do
    it { is_expected.to validate_presence_of(:message) }
  end

  describe "after_create_commit" do
    it "sends an email to the reviewer after creation" do
      review_response = build(:product_review_response, product_review:)

      expect do
        review_response.save!
      end.to have_enqueued_mail(CustomerMailer, :review_response).with(review_response)

      expect do
        review_response.update!(message: "Updated message")
      end.to_not have_enqueued_mail(CustomerMailer, :review_response)
    end
  end
end
