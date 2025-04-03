# frozen_string_literal: true

class ProfilePresenter
  attr_reader :pundit_user, :seller

  # seller is the profile being viewed within the consumer area
  # pundit_user.seller is the selected seller for the logged-in user (pundit_user.user) - which may be different from seller
  def initialize(pundit_user:, seller:)
    @pundit_user = pundit_user
    @seller = seller
  end

  def creator_profile
    {
      external_id: seller.external_id,
      avatar_url: seller.avatar_url,
      name: seller.name || seller.username,
      twitter_handle: seller.twitter_handle,
      subdomain: seller.subdomain,
    }
  end

  def profile_props(seller_custom_domain_url:, request:)
    shared_profile_props(seller_custom_domain_url:, request:)
  end

  def profile_settings_props(request:)
    memberships = seller.products.membership.alive.not_archived.includes(ProductPresenter::ASSOCIATIONS_FOR_CARD)
    shared_profile_props(seller_custom_domain_url: nil, request:, as_logged_out_user: true).merge(
      {
        profile_settings: {
          username: seller.username,
          name: seller.name,
          bio: seller.bio,
          font: seller.seller_profile.font,
          background_color: seller.seller_profile.background_color,
          highlight_color: seller.seller_profile.highlight_color,
          profile_picture_blob_id: seller.avatar.signed_id,
        },
        memberships: memberships.map { |product| ProductPresenter.card_for_web(product:, show_seller: false) },
      }
    )
  end

  private
    def shared_profile_props(seller_custom_domain_url:, request:, as_logged_out_user: false)
      pundit_user = as_logged_out_user ? SellerContext.logged_out : @pundit_user
      {
        **profile_sections_presenter.props(request:, pundit_user:, seller_custom_domain_url:),
        bio: seller.bio,
        tabs: (seller.seller_profile.json_data["tabs"] || [])
                .map { |tab| { name: tab["name"], sections: tab["sections"].map { ObfuscateIds.encrypt(_1) } } },
      }
    end

    def profile_sections_presenter
      ProfileSectionsPresenter.new(seller:, query: seller.seller_profile_sections.on_profile)
    end
end
