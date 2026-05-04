# frozen_string_literal: true

module RenderingExtension
  extend self

  def custom_context(view_context)
    pundit_user = view_context.pundit_user
    {
      design_settings: { font: { name: "ABC Favorit", url: view_context.font_url("ABCFavorit-Regular.woff2") } },
      domain_settings: {
        scheme: PROTOCOL,
        app_domain: DOMAIN,
        root_domain: ROOT_DOMAIN,
        short_domain: SHORT_DOMAIN,
        discover_domain: DISCOVER_DOMAIN,
        third_party_analytics_domain: THIRD_PARTY_ANALYTICS_DOMAIN,
        api_domain: API_DOMAIN,
      },
      user_agent_info: {
        is_mobile: view_context.controller.is_mobile?,
      },
      logged_in_user: logged_in_user_props(pundit_user, is_impersonating: view_context.controller.impersonating?),
      current_seller: current_seller_props(pundit_user),
      csp_nonce: SecureHeaders.content_security_policy_script_nonce(view_context.request),
      locale: view_context.controller.http_accept_language.user_preferred_languages[0] || "en-US",
      feature_flags: {
        require_email_typo_acknowledgment: Feature.active?(:require_email_typo_acknowledgment),
        disable_stripe_signup: Feature.active?(:disable_stripe_signup),
      }
    }
  end

  private
    def logged_in_user_props(pundit_user, is_impersonating:)
      user = pundit_user.user
      return nil unless user

      {
        id: user.external_id,
        email: user.email,
        name: user.name,
        avatar_url: user.avatar_url,
        confirmed: user.confirmed?,
        team_memberships: UserMembershipsPresenter.new(pundit_user:).props,
        policies: policies_props(pundit_user),
        is_gumroad_admin: user.is_team_member?,
        is_impersonating:,
        lazy_load_offscreen_discover_images: Feature.active?(:lazy_load_offscreen_discover_images, user),
      }
    end

    # Policies accessible via loggedInUser
    # Only used for policies that don't need record-specific logic, like LinkPolicy::edit? where a product record is required
    # Policies should be grouped by Policy class name
    # Naming convention:
    # - policy class key: Settings::Payments::UserPolicy.name.underscore.tr("/", "_").gsub(/(_policy)$/, "")
    # - policy method key: Settings::Payments::UserPolicy.instance_methods(false).first.to_s.chop
    #
    def policies_props(pundit_user)
      {
        affiliate_requests_onboarding_form: {
          update: Pundit.policy!(pundit_user, [:affiliate_requests, :onboarding_form]).update?,
        },
        direct_affiliate: {
          create: Pundit.policy!(pundit_user, DirectAffiliate).create?,
          update: Pundit.policy!(pundit_user, DirectAffiliate).update?,
        },
        collaborator: {
          create: Pundit.policy!(pundit_user, Collaborator).create?,
          update: Pundit.policy!(pundit_user, Collaborator).update?,
        },
        product: {
          create: Pundit.policy!(pundit_user, Link).create?,
        },
        product_review_response: {
          update: Pundit.policy!(pundit_user, ProductReviewResponse).update?,
        },
        balance: {
          index: Pundit.policy!(pundit_user, :balance).index?,
          export: Pundit.policy!(pundit_user, :balance).export?,
        },
        checkout_offer_code: {
          create: Pundit.policy!(pundit_user, [:checkout, OfferCode]).create?,
        },
        checkout_form: {
          update: Pundit.policy!(pundit_user, [:checkout, :form]).update?,
        },
        upsell: {
          create: Pundit.policy!(pundit_user, [:checkout, Upsell]).create?,
        },
        settings_payments_user: {
          show: Pundit.policy!(pundit_user, [:settings, :payments, pundit_user.seller]).show?,
        },
        settings_profile: {
          manage_social_connections: Pundit.policy!(pundit_user, [:settings, :profile]).manage_social_connections?,
          update: Pundit.policy!(pundit_user, [:settings, :profile]).update?,
          update_username: Pundit.policy!(pundit_user, [:settings, :profile]).update_username?
        },
        settings_third_party_analytics_user: {
          update: Pundit.policy!(pundit_user, [:settings, :third_party_analytics, pundit_user.seller]).update?
        },
        installment: {
          create: Pundit.policy!(pundit_user, Installment).create?,
        },
        workflow: {
          create: Pundit.policy!(pundit_user, Workflow).create?,
        },
        utm_link: {
          index: Pundit.policy!(pundit_user, :utm_link).index?,
        },
        community: {
          index: Pundit.policy!(pundit_user, Community).index?,
        },
        churn: {
          show: Pundit.policy!(pundit_user, :churn).show?,
        }
      }
    end

    def current_seller_props(pundit_user)
      seller = pundit_user.seller
      return nil unless seller

      UserPresenter.new(user: pundit_user.seller).as_current_seller
    end
end
