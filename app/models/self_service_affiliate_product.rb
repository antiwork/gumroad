# frozen_string_literal: true

class SelfServiceAffiliateProduct < ApplicationRecord
  include Affiliate::BasisPointsValidations
  include Affiliate::DestinationUrlValidations

  belongs_to :seller, class_name: "User", optional: true
  belongs_to :product, class_name: "Link", optional: true

  validates :seller, :product, presence: true
  validates :affiliate_basis_points, presence: true, if: :enabled?
  validate :affiliate_basis_points_must_fall_in_an_acceptable_range, if: :enabled?
  validate :product_is_not_a_collab, if: :enabled?
  validate :product_user_and_seller_is_same

  scope :enabled, -> { where(enabled: true) }

  def self.bulk_upsert!(products_with_details, seller_id)
    transaction do
      products_with_details.each do |product_details|
        self_service_affiliate_product = find_or_initialize_by(product_id: ObfuscateIds.decrypt_numeric(product_details[:id].to_i))
        self_service_affiliate_product.enabled = product_details[:enabled]
        self_service_affiliate_product.seller_id = seller_id
        self_service_affiliate_product.affiliate_basis_points = product_details[:fee_percent] ? product_details[:fee_percent].to_i * 100 : 0
        self_service_affiliate_product.destination_url = product_details[:destination_url]
        self_service_affiliate_product.save!
      end
    end
  end

  private
    def product_is_not_a_collab
      return unless product.present? && product.is_collab?
      errors.add :base, "Collab products cannot have affiliates"
    end

    def product_user_and_seller_is_same
      return if product_id.nil? || seller_id.nil?
      return if product.user == seller

      errors.add(:base, "The product '#{product.name}' does not belong to you (#{seller.email}).")
    end
end
