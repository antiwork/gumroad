# frozen_string_literal: true

class ProductReviewVideo < ApplicationRecord
  include ExternalId
  include Deletable

  belongs_to :product_review

  has_one :video_file, as: :record, dependent: :destroy
  validates :video_file, presence: true
  accepts_nested_attributes_for :video_file

  APPROVAL_STATUES = %w[pending_review approved rejected].freeze
  enum :approval_status, APPROVAL_STATUES.index_by(&:itself), default: :pending_review

  scope :editable, -> { where(approval_status: [:pending_review, :approved]) }
  scope :latest, -> { order(created_at: :desc) }

  APPROVAL_STATUES.each do |status|
    define_method("#{status}!".to_sym) do
      ProductReviewVideo.transaction do
        product_review.with_lock do
          product_review.videos
            .where.not(id: id)
            .where(approval_status: status)
            .each(&:mark_deleted!)
          super()
        end
      end
    end
  end
end
