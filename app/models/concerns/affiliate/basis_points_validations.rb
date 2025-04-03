# frozen_string_literal: true

module Affiliate::BasisPointsValidations
  extend ActiveSupport::Concern

  MIN_AFFILIATE_BASIS_POINTS = 100 # 1%
  MAX_AFFILIATE_BASIS_POINTS = 7500 # 75%

  included do
    private
      def affiliate_basis_points_must_fall_in_an_acceptable_range
        return if affiliate_basis_points.nil?
        return if affiliate_basis_points >= MIN_AFFILIATE_BASIS_POINTS && affiliate_basis_points <= MAX_AFFILIATE_BASIS_POINTS

        errors.add(:base, "Affiliate commission must be between #{MIN_AFFILIATE_BASIS_POINTS / 100}% and #{MAX_AFFILIATE_BASIS_POINTS / 100}%.")
      end
  end
end
