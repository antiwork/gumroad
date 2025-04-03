# frozen_string_literal: true

class ProductAffiliate < ApplicationRecord
  include FlagShihTzu

  self.table_name = "affiliates_links"

  belongs_to :affiliate
  belongs_to :product, class_name: "Link", foreign_key: :link_id

  validates :affiliate, uniqueness: { scope: :product }
  validates :affiliate_basis_points, presence: true, if: -> { affiliate.is_a?(Collaborator) && !affiliate.apply_to_all_products? }
  validates :affiliate_basis_points, numericality: { greater_than_or_equal_to: Collaborator::MIN_PERCENT_COMMISSION * 100,
                                                     less_than_or_equal_to: Collaborator::MAX_PERCENT_COMMISSION * 100,
                                                     allow_nil: true }, if: -> { affiliate.is_a?(Collaborator) }
  validate :product_is_eligible_for_collabs, if: -> { affiliate.is_a?(Collaborator) }
  validate :product_is_not_a_collab, if: -> { affiliate.is_a?(DirectAffiliate) }
  after_create :enable_product_collaborator_flag_and_disable_affiliates, if: -> { affiliate.is_a?(Collaborator) }
  after_destroy :disable_product_collaborator_flag, if: -> { affiliate.is_a?(Collaborator) }
  after_create :update_audience_member_with_added_product
  after_destroy :update_audience_member_with_removed_product

  has_flags 1 => :dont_show_as_co_creator

  def affiliate_percentage
    return unless affiliate_basis_points.present?
    affiliate_basis_points / 100
  end

  private
    def enable_product_collaborator_flag_and_disable_affiliates
      product.update!(is_collab: true)
      product.self_service_affiliate_products.map { _1.update!(enabled: false) }
      product.product_affiliates.where.not(id:).joins(:affiliate).merge(Affiliate.direct_affiliates).map { _1.destroy! }
    end

    def disable_product_collaborator_flag
      product.update!(is_collab: false)
    end

    def update_audience_member_with_added_product
      affiliate.update_audience_member_with_added_product(link_id)
    end

    def update_audience_member_with_removed_product
      affiliate.update_audience_member_with_removed_product(link_id)
    end

    def product_is_eligible_for_collabs
      return unless product.has_another_collaborator?(collaborator: affiliate)
      errors.add :base, "This product is not eligible for the Gumroad Affiliate Program."
    end

    def product_is_not_a_collab
      return unless product.is_collab?
      errors.add :base, "Collab products cannot have affiliates"
    end
end
