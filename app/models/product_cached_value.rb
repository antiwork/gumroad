# frozen_string_literal: true

class ProductCachedValue < ApplicationRecord
  belongs_to :product, class_name: "Link", optional: true

  before_create :assign_cached_values

  validates_presence_of :product

  scope :fresh, -> { where(expired: false) }
  scope :expired, -> { where(expired: true) }

  def expire!
    update!(expired: true)
  end

  private
    def assign_cached_values
      self.assign_attributes(
        successful_sales_count: product.successful_sales_count,
        remaining_for_sale_count: product.remaining_for_sale_count,
        monthly_recurring_revenue: product.monthly_recurring_revenue,
        revenue_pending: product.revenue_pending,
        total_usd_cents: product.total_usd_cents,
      )
    end
end
