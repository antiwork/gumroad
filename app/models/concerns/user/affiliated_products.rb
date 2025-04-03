# frozen_string_literal: true

module User::AffiliatedProducts
  extend ActiveSupport::Concern

  def directly_affiliated_products(alive: true)
    scope = Link.with_direct_affiliates
    scope = scope.merge(DirectAffiliate.alive).alive if alive

    scope.for_affiliate_user(id)
  end
end
