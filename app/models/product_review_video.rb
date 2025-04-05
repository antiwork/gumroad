# frozen_string_literal: true

class ProductReviewVideo < ApplicationRecord
  include ExternalId
  include Deletable

  belongs_to :product_review

  has_one :video_file, as: :record, dependent: :destroy
  validates :video_file, presence: true

  enum :approval_status,
       %w[pending_review approved rejected].index_by(&:itself),
       default: :pending_review
end
