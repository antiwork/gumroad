# frozen_string_literal: true

# Public identity of a partner seller: the partner's own user ID plus the seller's public
# Gumroad profile. No email, balance or sales data.
class PartnerSellerPresenter
  def initialize(partner_seller:)
    @partner_seller = partner_seller
  end

  def props
    user = partner_seller.user

    {
      external_user_id: partner_seller.external_user_id,
      name: user.name_or_username,
      avatar_url: user.avatar_url,
      profile_url: user.profile_url,
    }
  end

  private
    attr_reader :partner_seller
end
