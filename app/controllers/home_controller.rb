# frozen_string_literal: true

class HomeController < ApplicationController
  layout "home"

  # Static marketing pages served on the root domain. Their content doesn't
  # depend on who is asking, so we let the CDN (Cloudflare) cache them for
  # anonymous visitors instead of paying a full origin round trip on every
  # first visit (cold hits on gumroad.com were measured at ~9.7s vs ~25ms of
  # actual origin work).
  #
  # We only mark a response as publicly cacheable when the request carries NO
  # cookies at all. That condition is deliberate:
  # - A signed-in visitor always carries the session cookie
  #   (_gumroad_app_session, see config/initializers/session_store.rb), so
  #   they bypass the shared cache and keep seeing the "Dashboard" nav instead
  #   of a cached "Log in" variant.
  # - A returning anonymous visitor carries _gumroad_guid; they also bypass.
  # - The remaining population — first-time, cookie-less visitors — is exactly
  #   the cold-hit traffic we want served from the edge, and for them the
  #   session is empty so there is nothing user-specific to leak.
  #
  # For those cacheable responses we must not emit Set-Cookie (CDNs refuse to
  # cache, and a shared cache must never capture a visitor's cookies), so we
  # skip the session write and the _gumroad_guid analytics cookie. Requests
  # with UTM parameters are excluded because UTM visit tracking
  # (UtmLinkTracking) needs the _gumroad_guid cookie to exist.
  #
  # Note: these headers are advisory until a Cloudflare Cache Rule makes HTML
  # eligible for caching; without that rule behavior is unchanged in
  # production.
  EDGE_CACHEABLE_ACTIONS = %w[about features features_md pricing terms privacy prohibited dpa hackathon saas small_bets].freeze

  prepend_before_action :prepare_edge_cacheable_response, if: :edge_cacheable_request?
  after_action :set_edge_cache_headers, if: -> { @edge_cacheable_response }

  before_action :hide_layouts

  def about
    set_meta_tag(title: "Earn your first dollar online with Gumroad")
    set_meta_tag(name: "description", content: "Start selling what you know, see what sticks, and get paid. Simple and effective.")
    set_meta_tag(tag_name: "link", rel: "canonical", href: about_url, head_key: "canonical")
    set_meta_tag(property: "og:title", content: "Earn your first dollar online with Gumroad")
    set_meta_tag(property: "og:description", content: "Start selling what you know, see what sticks, and get paid. Simple and effective.")
    set_meta_tag(property: "og:type", content: "website")
    set_meta_tag(property: "og:url", content: about_url)
  end

  def features
    set_meta_tag(title: "Gumroad features: Simple and powerful e-commerce tools")
    set_meta_tag(name: "description", content: "Sell books, memberships, courses, and more with Gumroad's simple e-commerce tools. Everything you need to grow your audience.")
    set_meta_tag(tag_name: "link", rel: "canonical", href: features_url, head_key: "canonical")
    set_meta_tag(property: "og:title", content: "Gumroad features: Simple and powerful e-commerce tools")
    set_meta_tag(property: "og:description", content: "Sell books, memberships, courses, and more with Gumroad's simple e-commerce tools. Everything you need to grow your audience.")
    set_meta_tag(property: "og:type", content: "website")
    set_meta_tag(property: "og:url", content: features_url)
  end

  def hackathon
    set_meta_tag(title: "Gumroad $100K Niche Marketplace Hackathon")
    set_meta_tag(name: "description", content: "Build a niche marketplace using Gumroad OSS. $100K in prizes for the best marketplace ideas and implementations.")
    set_meta_tag(tag_name: "link", rel: "canonical", href: hackathon_url, head_key: "canonical")
    set_meta_tag(property: "og:title", content: "Gumroad $100K Niche Marketplace Hackathon")
    set_meta_tag(property: "og:description", content: "Build a niche marketplace using Gumroad OSS. $100K in prizes for the best marketplace ideas and implementations.")
    set_meta_tag(property: "og:type", content: "website")
    set_meta_tag(property: "og:url", content: hackathon_url)
  end

  def pricing
    set_meta_tag(title: "Gumroad pricing: 10% flat fee")
    set_meta_tag(name: "description", content: "No monthly fees, just a simple 10% cut per sale. Gumroad's pricing is transparent and creator-friendly.")
    set_meta_tag(tag_name: "link", rel: "canonical", href: pricing_url, head_key: "canonical")
    set_meta_tag(property: "og:title", content: "Gumroad pricing: 10% flat fee")
    set_meta_tag(property: "og:description", content: "No monthly fees, just a simple 10% cut per sale. Gumroad's pricing is transparent and creator-friendly.")
    set_meta_tag(property: "og:type", content: "website")
    set_meta_tag(property: "og:url", content: pricing_url)
  end

  def privacy
    set_meta_tag(title: "Gumroad privacy policy: how we protect your data")
    set_meta_tag(name: "description", content: "Learn how Gumroad collects, uses, and protects your personal information. Your privacy matters to us.")
    set_meta_tag(tag_name: "link", rel: "canonical", href: privacy_url, head_key: "canonical")
    set_meta_tag(property: "og:title", content: "Gumroad privacy policy: how we protect your data")
    set_meta_tag(property: "og:description", content: "Learn how Gumroad collects, uses, and protects your personal information. Your privacy matters to us.")
    set_meta_tag(property: "og:type", content: "website")
    set_meta_tag(property: "og:url", content: privacy_url)
  end

  def dpa
    set_meta_tag(title: "Gumroad data processing addendum")
    set_meta_tag(name: "description", content: "Gumroad's Data Processing Addendum for sellers, covering GDPR Article 28 processor terms, subprocessors, and international transfers.")
    set_meta_tag(tag_name: "link", rel: "canonical", href: dpa_url, head_key: "canonical")
    set_meta_tag(property: "og:title", content: "Gumroad data processing addendum")
    set_meta_tag(property: "og:description", content: "Gumroad's Data Processing Addendum for sellers, covering GDPR Article 28 processor terms, subprocessors, and international transfers.")
    set_meta_tag(property: "og:type", content: "website")
    set_meta_tag(property: "og:url", content: dpa_url)
  end

  def prohibited
    set_meta_tag(title: "Prohibited products on Gumroad")
    set_meta_tag(name: "description", content: "Understand what products and activities are not allowed on Gumroad to comply with our policies.")
    set_meta_tag(tag_name: "link", rel: "canonical", href: prohibited_url, head_key: "canonical")
    set_meta_tag(property: "og:title", content: "Prohibited products on Gumroad")
    set_meta_tag(property: "og:description", content: "Understand what products and activities are not allowed on Gumroad to comply with our policies.")
    set_meta_tag(property: "og:type", content: "website")
    set_meta_tag(property: "og:url", content: prohibited_url)
  end

  def terms
    set_meta_tag(title: "Gumroad terms of service")
    set_meta_tag(name: "description", content: "Review the rules and guidelines for using Gumroad's services. Stay informed and compliant.")
    set_meta_tag(tag_name: "link", rel: "canonical", href: terms_url, head_key: "canonical")
    set_meta_tag(property: "og:title", content: "Gumroad terms of service")
    set_meta_tag(property: "og:description", content: "Review the rules and guidelines for using Gumroad's services. Stay informed and compliant.")
    set_meta_tag(property: "og:type", content: "website")
    set_meta_tag(property: "og:url", content: terms_url)
  end

  def features_md
    render plain: FeaturesMarkdownGenerator.call, content_type: "text/markdown"
  end

  def saas
    set_meta_tag(title: "Gumroad for SaaS: Sell software with license keys, subscriptions, and more")
    set_meta_tag(name: "description", content: "Sell software and SaaS with Gumroad. We handle checkout, license keys, subscriptions, taxes, fraud, and chargebacks so you can keep building.")
    set_meta_tag(tag_name: "link", rel: "canonical", href: saas_url, head_key: "canonical")
    set_meta_tag(property: "og:title", content: "Gumroad for SaaS: Sell software with license keys, subscriptions, and more")
    set_meta_tag(property: "og:description", content: "Sell software and SaaS with Gumroad. We handle checkout, license keys, subscriptions, taxes, fraud, and chargebacks so you can keep building.")
    set_meta_tag(property: "og:type", content: "website")
    set_meta_tag(property: "og:url", content: saas_url)
  end

  def small_bets
    set_meta_tag(title: "Small Bets by Gumroad")
    set_meta_tag(name: "description", content: "Explore the Small Bets initiative by Gumroad. Learn, experiment, and grow with small, actionable projects.")
    set_meta_tag(tag_name: "link", rel: "canonical", href: small_bets_url, head_key: "canonical")
    set_meta_tag(property: "og:title", content: "Small Bets by Gumroad")
    set_meta_tag(property: "og:description", content: "Explore the Small Bets initiative by Gumroad. Learn, experiment, and grow with small, actionable projects.")
    set_meta_tag(property: "og:type", content: "website")
    set_meta_tag(property: "og:url", content: small_bets_url)
  end

  private
    def hide_layouts
      @hide_layouts = true
    end

    def edge_cacheable_request?
      request.get? && request.cookies.empty? && !user_signed_in? &&
        EDGE_CACHEABLE_ACTIONS.include?(action_name) &&
        params.keys.none? { |key| key.start_with?("utm_") }
    end

    # Runs before ApplicationController's callbacks (prepend_before_action) so
    # the session is already marked as skipped by the time callbacks like
    # set_recommender_model_name and set_signup_referrer try to write to it —
    # otherwise those writes would emit a Set-Cookie and defeat CDN caching.
    def prepare_edge_cacheable_response
      @edge_cacheable_response = true
      request.session_options[:skip] = true
    end

    # ApplicationController sets a _gumroad_guid analytics cookie for every
    # visitor that doesn't have one. Skip it on edge-cacheable responses: a
    # Set-Cookie header prevents CDN caching, and a shared cache must never
    # hand one visitor's guid to another. The guid gets assigned on the
    # visitor's first non-marketing-page request instead.
    def set_gumroad_guid
      return if @edge_cacheable_response

      super
    end

    # inertia_rails adds an after_action that writes an XSRF-TOKEN cookie
    # whenever forgery protection is on. These marketing pages are GET-only —
    # the footer's follow form already posts without an authenticity token
    # (it's static HTML) and relies on the app's null-session forgery
    # strategy — so on edge-cacheable responses we turn forgery protection
    # off to keep the response cookie-free. A per-visitor CSRF token baked
    # into shared cached HTML would be useless anyway: every visitor would
    # receive the same token.
    def protect_against_forgery?
      return false if @edge_cacheable_response

      super
    end

    def set_edge_cache_headers
      return unless response.status == 200
      # Belt and braces: if anything still wrote a cookie, keep the default
      # private cache behavior rather than letting a shared cache store it.
      return if response.headers["Set-Cookie"].present?

      # Browsers revalidate after 60s; the CDN keeps a copy for 5 minutes
      # (s-maxage) and may serve it stale for up to an hour while it refetches
      # in the background (stale-while-revalidate). Rails serializes this as:
      # "max-age=60, public, stale-while-revalidate=3600, s-maxage=300".
      expires_in 1.minute, public: true, "s-maxage": 5.minutes, stale_while_revalidate: 1.hour
    end
end
