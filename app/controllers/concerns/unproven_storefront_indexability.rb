# frozen_string_literal: true

# Keeps an unproven seller's storefront surfaces out of search results. Spam accounts create
# storefronts in bulk (gambling and fake login pages) and Google flags the whole domain for
# them, so nothing a seller has authored is offered for indexing until a human marks them
# `compliant` or they make a real (non-free) sale. Buyers who already have the link are
# unaffected — only search engines are told to skip it — and the header goes away the moment
# either condition is met.
#
# Shared by every controller that serves seller-authored storefront content: the profile
# (UsersController) and the seller's Pages (UserPagesController), which are a separate route
# on the same subdomain and were missed when this shipped for the profile.
module UnprovenStorefrontIndexability
  extend ActiveSupport::Concern

  private
    def set_noindex_header_for_unproven_storefront
      return if @user.blank?
      return if @user.compliant?
      return if @user.sales.successful.non_free.exists?

      set_noindex_header
    end
end
