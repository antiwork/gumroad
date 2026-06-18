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
      is_verified: !!seller.verified,
      can_edit: can_edit_profile?,
    }
  end

  def profile_props(seller_custom_domain_url:, request:)
    # editing: false keeps the public profile on the visitor section shape - the inline editor moved
    # to /profile, so the public component no longer renders the owner/editing shape. The real viewer
    # is still passed through, so "you own this", "already following this wishlist", and currency
    # reflect them (including the seller viewing their own page).
    shared_profile_props(seller_custom_domain_url:, request:, editing: false).merge(creator_profile:)
  end

  def profile_settings_props(request:)
    memberships = seller.products.membership.alive.not_archived.includes(ProductPresenter::ASSOCIATIONS_FOR_CARD)
    # Sample the version before reading the editor payload below. If a concurrent save lands in
    # between, the payload may be newer than this token — which makes the next save a harmless
    # false-stale rejection rather than letting a stale token wave a lost update through.
    profile_version = seller.seller_profile.layout_version&.iso8601(6)
    shared_profile_props(seller_custom_domain_url: nil, request:, pundit_user: SellerContext.logged_out).merge(
      {
        profile_settings: {
          name: seller.name,
          bio: seller.bio,
          profile_picture_blob_id: seller.avatar.signed_id,
        },
        editable_profile: shared_profile_props(seller_custom_domain_url: nil, request:),
        # Version stamp for optimistic concurrency: the editor sends it back on save so the server
        # can reject a stale pages/sections write. Nil for a not-yet-saved profile.
        profile_version:,
        memberships: memberships.map { |product| ProductPresenter.card_for_web(product:, show_seller: false) },
      }
    )
  end

  private
    def shared_profile_props(seller_custom_domain_url:, request:, pundit_user: @pundit_user, editing: pundit_user.seller == seller)
      {
        **profile_sections_presenter.props(request:, pundit_user:, seller_custom_domain_url:, editing:),
        bio: seller.bio,
        tabs: (seller.seller_profile.json_data["tabs"] || [])
                .map { |tab| { name: tab["name"], sections: tab["sections"].map { ObfuscateIds.encrypt(_1) } } },
      }
    end

    def profile_sections_presenter
      ProfileSectionsPresenter.new(seller:, query: seller.seller_profile_sections.on_profile)
    end

    def can_edit_profile?
      pundit_user&.user.present? &&
        pundit_user.seller == seller &&
        Pundit.policy!(pundit_user, [:settings, :profile]).update?
    end
end
