# frozen_string_literal: true

class Marketing::HoldoutAssignment < ApplicationRecord
  SALES_BUCKETS = %w[zero under_100 at_least_100].freeze
  SALES_THRESHOLD_CENTS = 100_00
  HOLDOUT_PERCENTAGE = 20

  belongs_to :user

  validates :prior_sales_bucket, inclusion: { in: SALES_BUCKETS }
  validates :marketing_holdout, inclusion: { in: [true, false] }
  validates :marketing_holdout_assigned_at, presence: true

  # Freeze both the stratum and assignment before the seller can see treatment.
  def self.for_seller!(seller)
    find_by(user_id: seller.id) || create_or_find_by!(user_id: seller.id) do |assignment|
      sales_cents = seller.gross_sales_cents_total_as_seller
      assignment.prior_sales_bucket = if sales_cents <= 0
        "zero"
      elsif sales_cents < SALES_THRESHOLD_CENTS
        "under_100"
      else
        "at_least_100"
      end
      assignment.marketing_holdout = bucket_for(seller.id, assignment.prior_sales_bucket) < HOLDOUT_PERCENTAGE
      assignment.marketing_holdout_assigned_at = Time.current
    end
  end

  def self.bucket_for(seller_id, prior_sales_bucket)
    Digest::SHA256.hexdigest("auto_marketing:v1:#{prior_sales_bucket}:#{seller_id}").to_i(16) % 100
  end

  def readonly? = persisted?
end
