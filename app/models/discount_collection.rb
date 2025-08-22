# frozen_string_literal: true

class DiscountCollection < ApplicationRecord
  include ExternalId
  include Deletable

  belongs_to :user
        has_many :offer_codes, dependent: :nullify

  validates :name, presence: true
  validates :user, presence: true

  scope :alive, -> { where(deleted_at: nil) }

        def offer_codes_count
        offer_codes.count
      end

  def total_uses
    offer_codes.joins(:purchases).sum('purchases.quantity')
  end

  def total_revenue_cents
    offer_codes.joins(:purchases).sum('purchases.price_cents')
  end

  def has_defaults?
    default_discount_type.present? ||
    default_discount_value.present? ||
    default_max_purchase_count.present? ||
    default_valid_at.present? ||
    default_expires_at.present? ||
    default_minimum_quantity.present? ||
    default_duration_in_billing_cycles.present? ||
    default_minimum_amount_cents.present?
  end

  def export_to_csv
    require 'csv'

    CSV.generate(headers: true) do |csv|
      csv << ['Code', 'Name', 'Discount Type', 'Discount Value', 'Products', 'Max Uses', 'Valid From', 'Expires At', 'Created At']

      offer_codes.alive.each do |offer_code|
        csv << [
          offer_code.code,
          offer_code.name,
          offer_code.amount_percentage.present? ? 'percent' : 'cents',
          offer_code.amount_percentage || offer_code.amount_cents,
          offer_code.products.map(&:name).join(', '),
          offer_code.max_purchase_count,
          offer_code.valid_at&.strftime('%Y-%m-%d'),
          offer_code.expires_at&.strftime('%Y-%m-%d'),
          offer_code.created_at.strftime('%Y-%m-%d %H:%M:%S')
        ]
      end
    end
  end

  def generate_quick_code(name)
    user.offer_codes.build(
      name: name,
      code: generate_unique_code,
      discount_collection: self,
      universal: true,
      max_purchase_count: default_max_purchase_count,
      amount_percentage: default_discount_type == 'percent' ? default_discount_value : nil,
      amount_cents: default_discount_type == 'cents' ? default_discount_value : nil,
      valid_at: default_valid_at,
      expires_at: default_expires_at,
      minimum_quantity: default_minimum_quantity,
      duration_in_billing_cycles: default_duration_in_billing_cycles,
      minimum_amount_cents: default_minimum_amount_cents
    )
  end

  def generate_unique_code
    loop do
      code = SecureRandom.alphanumeric(8).upcase
      break code unless user.offer_codes.alive.exists?(code: code)
    end
  end

  private
end
