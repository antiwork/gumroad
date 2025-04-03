# frozen_string_literal: true

class ProductReviewResponse < ApplicationRecord
  belongs_to :user
  belongs_to :product_review

  validates :message, presence: true

  after_create_commit :notify_reviewer_via_email

  private
    def notify_reviewer_via_email
      CustomerMailer.review_response(self).deliver_later
    end
end
