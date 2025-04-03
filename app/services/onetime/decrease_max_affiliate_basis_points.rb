# frozen_string_literal: true

class Onetime::DecreaseMaxAffiliateBasisPoints
  def self.process
    SelfServiceAffiliateProduct.where("affiliate_basis_points > ?", max_affiliate_basis_points).find_each do |affiliate_product|
      affiliate_product.update(affiliate_basis_points: max_affiliate_basis_points)
    end

    Affiliate.where("affiliate_basis_points > ?", max_affiliate_basis_points).find_each do |affiliate|
      affiliate.update(affiliate_basis_points: max_affiliate_basis_points)
    end
  end

  def self.max_affiliate_basis_points
    Affiliate::BasisPointsValidations::MAX_AFFILIATE_BASIS_POINTS
  end
end
