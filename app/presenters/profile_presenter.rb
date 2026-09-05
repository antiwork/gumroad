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
      youtube_channel_id: seller.youtube_identity&.channel_id,
      subdomain: seller.subdomain,
      is_verified: !!seller.verified,
      can_edit: can_edit_profile?,
      # Non-nil only when this seller's subscribe form has to pass a CAPTCHA
      # (see FollowRecaptcha). The follow form executes the challenge with this
      # key and FollowersController verifies the resulting token against the
      # same one, since Google ties a token to the key that produced it.
      follow_recaptcha_site_key: FollowRecaptcha.required?(seller) ? FollowRecaptcha.site_key : nil,
      hide_follow_form: seller.hide_follow_form?,
      # Key present only while the flag is on, so flipping it off removes the
      # surface entirely instead of shipping a null the frontend must know about.
      **(seller.reputation_summary_enabled? ? { reputation: seller.seller_reputation_summary } : {}),
    }
  end

  def profile_props(seller_custom_domain_url:, request:)
    # Public page uses the visitor section shape (inline editor lives at /profile).
    # include_default_products_section synthesizes a products section when the creator
    # has products but no saved sections; the editor never requests it.
    shared_profile_props(seller_custom_domain_url:, request:, editing: false, include_default_products_section: true).merge(creator_profile:, seller_analytics:)
  end

  def profile_settings_props(request:)
    instagram_verification = seller.social_connect_verifications.find_by(platform: "instagram")
    memberships = seller.products.membership.alive.not_archived.includes(ProductPresenter::ASSOCIATIONS_FOR_CARD)
    # Sample the version before reading the editor payload below. If a concurrent save lands in
    # between, the payload may be newer than this token — which makes the next save a harmless
    # false-stale rejection rather than letting a stale token wave a lost update through.
    profile_version = seller.seller_profile.layout_version
    # Settings::ProfileController#update rejects every save until the seller is confirmed, so gate
    # this on `confirmed?` rather than `has_unconfirmed_email?` — the latter is also true for a
    # confirmed seller with a pending address change, who can still save.
    email_confirmation = unless seller.confirmed?
      confirmation_email = seller.unconfirmed_email.presence || seller.email.presence
      {
        email: confirmation_email,
        can_resend: confirmation_email.present? && Pundit.policy!(pundit_user, [:settings, :main, seller]).resend_confirmation_email?,
      }
    end
    shared_profile_props(seller_custom_domain_url: nil, request:, pundit_user: SellerContext.logged_out).merge(
      {
        profile_settings: {
          name: seller.name,
          bio: seller.bio,
          font: seller.seller_profile.font,
          background_color: HexColorValidator.normalize(seller.seller_profile.background_color),
          highlight_color: HexColorValidator.normalize(seller.seller_profile.highlight_color),
          profile_picture_blob_id: seller.avatar.signed_id,
          product_page_storefront_enabled: seller.product_page_storefront_enabled?,
          hide_follow_form: seller.hide_follow_form?,
        },
        editable_profile: shared_profile_props(seller_custom_domain_url: nil, request:),
        # Version stamp for optimistic concurrency: the editor sends it back on save so the server
        # can reject a stale pages/sections write. Unsaved empty profiles use the same fingerprint
        # as a newly persisted profile whose layout is still empty.
        profile_version:,
        memberships: memberships.map { |product| ProductPresenter.card_for_web(product:, show_seller: false) },
        seller_fonts_css_source: SellerProfile.seller_fonts_css_source,
        email_confirmation:,
        # Custom-HTML profile landing page (#5553). Authored solely via the seller's agent + the
        # `gumroad user page` CLI (no inline editor) - these props drive the "Build with your agent"
        # affordance: the live-status banner, the copy-prompt block, and the reset button. The
        # username feeds the agent prompt. The HTML itself is never sent here - the form never edits
        # it, it only sends "" to reset, so has_custom_landing_page is all the UI needs.
        custom_html_pages_enabled: Feature.active?(:custom_html_pages, seller),
        youtube_connect_enabled: Feature.active?(:youtube_connect, seller),
        youtube_connected: seller.youtube_identity.present?,
        youtube_handle: seller.youtube_identity&.handle,
        instagram_connect_enabled: Feature.active?(:instagram_connect, seller),
        instagram_connected: instagram_verification.present?,
        instagram_handle: instagram_verification&.handle,
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
      if include_default_products_section
        if sections_props[:sections].any? { _1[:id] == ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID }
          tabs = [{ name: ProfileSectionsPresenter::DEFAULT_PRODUCTS_TAB_NAME, sections: [ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID] }]
        else
          # Sections can also exist while no tab references any of them (the editor can persist an
          # empty tab); serve one tab pointing at every saved section. Fires only when no tab would
          # render anything, and sorts by id because the query has no ORDER BY and this is user-visible.
          section_ids = sections_props[:sections].map { _1[:id] }.sort_by { ObfuscateIds.decrypt(_1) }
          if section_ids.any? && tabs.none? { |tab| tab[:sections].intersect?(section_ids) }
            tabs = [{ name: tabs.first&.dig(:name) || ProfileSectionsPresenter::DEFAULT_PRODUCTS_TAB_NAME, sections: section_ids }]
          end
        end
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

    # Profile tracking props for Users/Show. Pixel ids only — shouldTrack() still gates
    # GA/FB/TikTok. Universal snippet iframe has no shouldTrack() guard, so enablement
    # is server-side here (third_party_analytics_enabled?). Location "all" only;
    # snippet URL is username-based.
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
