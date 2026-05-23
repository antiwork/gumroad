# frozen_string_literal: true

require "test_helper"

class ProductReviewResponseTest < ActiveSupport::TestCase
  self.described_class = ProductReviewResponse



  context_ ProductReviewResponse do
    let(:product_review) { create(:product_review) }

  context_ "validations" do
      it { is_expected.to validate_presence_of(:message) }
    end

  context_ "after_create_commit" do
  test "sends an email to the reviewer after creation" do
        review_response = build(:product_review_response, product_review:)

        expect do
          review_response.save!
        end.to have_enqueued_mail(CustomerMailer, :review_response).with(review_response)

        expect do
          review_response.update!(message: "Updated message")
        end.not_to have_enqueued_mail(CustomerMailer, :review_response)
      end
    end
  end
end
