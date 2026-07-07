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
    # include_default_products_section only applies to the public page: creators with products
    # but no saved sections get a virtual products section instead of a bare email signup box.
    # The profile editor (profile_settings_props below) never asks for it, so the editing
    # experience is unchanged.
    shared_profile_props(seller_custom_domain_url:, request:, editing: false, include_default_products_section: true).merge(creator_profile:, seller_analytics:)
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
        # Custom-HTML profile landing page (#5553). Authored solely via the seller's agent + the
        # `gumroad user page` CLI (no inline editor) - these props drive the "Build with your agent"
        # affordance: the live-status banner, the copy-prompt block, and the reset button. The
        # username feeds the agent prompt. The HTML itself is never sent here - the form never edits
        # it, it only sends "" to reset, so has_custom_landing_page is all the UI needs.
        custom_html_pages_enabled: Feature.active?(:custom_html_pages, seller),
        has_custom_landing_page: seller.has_custom_landing_page?,
        username: seller.username,
      }
    )
  end

  private
    def shared_profile_props(seller_custom_domain_url:, request:, pundit_user: @pundit_user, editing: pundit_user.seller == seller, include_default_products_section: false)
      sections_props = profile_sections_presenter.props(request:, pundit_user:, seller_custom_domain_url:, editing:, include_default_products_section:)
      tabs = (seller.seller_profile.json_data["tabs"] || [])
               .map { |tab| { name: tab["name"], sections: tab["sections"].map { ObfuscateIds.encrypt(_1) } } }
      # The frontend only renders sections that a tab points at, so when the presenter injected
      # the virtual default products section (only possible when the creator has no saved
      # sections), replace the tabs with a single tab that points at it. Any leftover saved tabs
      # can't reference real sections here - there are none.
      if include_default_products_section &&
         sections_props[:sections].any? { _1[:id] == ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID }
        tabs = [{ name: "Products", sections: [ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID] }]
      end
      {
        **sections_props,
        bio: seller.bio,
        tabs:,
      }
    end

    def profile_sections_presenter
      ProfileSectionsPresenter.new(seller:, query: seller.seller_profile_sections.on_profile)
    end

    # Seller GA/pixels never fired on the profile: startTrackingForSeller is only
    # called from product/checkout surfaces (#5676). These props let Users/Show
    # boot the account-scoped tracking. The GA/FB/TikTok pixels stay gated on the
    # gr:*:enabled meta tags the frontend already checks via shouldTrack(), so
    # this only supplies the ids for them. The universal raw-snippet iframe has
    # NO shouldTrack() guard (addProfileThirdPartyAnalytics appends it directly),
    # so its enablement must be honored server-side here — mirroring the custom
    # HTML path's analytics_enabled?(seller:) gate (production/staging only, plus
    # the seller's disable_third_party_analytics opt-out). Universal snippets are
    # limited to location "all": "product"/"receipt" scope a snippet to the
    # purchase flow, which a profile is not. The snippet iframe URL is
    # username-based, so it's only offered when a username exists.
    def seller_analytics
      {
        seller_id: seller.external_id,
        analytics: seller.analytics_data,
        has_universal_third_party_analytics:
          third_party_analytics_enabled? &&
          seller.username.present? &&
          seller.third_party_analytics.universal.alive.where(location: "all").exists?,
        username: seller.username,
      }
    end

    # Mirrors PageMeta::Analytics#analytics_enabled? for the universal-snippet
    # iframe, which the frontend cannot gate with shouldTrack(). The profile show
    # path never sets @disable_third_party_analytics, so only the environment gate
    # and the per-seller opt-out apply here.
    def third_party_analytics_enabled?
      return false if !Rails.env.production? && !Rails.env.staging?

      !seller.disable_third_party_analytics?
    end

    def can_edit_profile?
      pundit_user&.user.present? &&
        pundit_user.seller == seller &&
        Pundit.policy!(pundit_user, [:settings, :profile]).update?
    end
end
