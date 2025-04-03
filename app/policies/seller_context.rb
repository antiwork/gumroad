# frozen_string_literal: true

class SellerContext
  attr_reader :user, :seller

  # Special context when pundit_user is used in a context where the presenter works with user not being
  # authenticated. Usually, this is because the presenter is used for both public and seller areas.
  def self.logged_out
    new(user: nil, seller: nil)
  end

  def initialize(user:, seller:)
    @user = user
    @seller = seller
  end
end
