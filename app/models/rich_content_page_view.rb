# frozen_string_literal: true

class RichContentPageView < ApplicationRecord
  include TimestampScopes

  belongs_to :rich_content
  belongs_to :purchase
  belongs_to :product, foreign_key: :product_id, class_name: "Link"
  belongs_to :buyer, foreign_key: :buyer_id, class_name: "User", optional: true

  validates :rich_content_id, presence: true
  validates :purchase_id, presence: true
  validates :product_id, presence: true
  validates :viewed_at, presence: true

  scope :for_product, ->(product_id) { where(product_id:) }
  scope :for_rich_content, ->(rich_content_id) { where(rich_content_id:) }
  scope :in_date_range, ->(start_date, end_date) { where(viewed_at: start_date.beginning_of_day..end_date.end_of_day) }

  def self.record_view!(rich_content_id:, purchase_id:, product_id:, buyer_id: nil, url_redirect_id: nil, ip_address: nil, user_agent: nil, viewed_at: Time.current)
    create!(
      rich_content_id:,
      purchase_id:,
      product_id:,
      buyer_id:,
      url_redirect_id:,
      ip_address:,
      user_agent:,
      viewed_at:
    )
  end
end
