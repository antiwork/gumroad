# frozen_string_literal: true

# A custom page on a seller's storefront (or, for products, the product page
# takeover — the original use of this table).
#
# Two kinds of rows:
#
# - The ROOT page (slug is NULL): the original one-per-owner custom HTML
#   takeover. For a user it replaces the whole profile; for a product it
#   replaces the product page. There is at most one per owner.
# - SLUGGED pages (first-class Pages, gumroad-private#1047): additional pages a
#   seller publishes under their storefront at /<slug>. Each has a title and
#   either rich text `content` (written in the in-app editor) or `custom_html`
#   (a full-HTML takeover pushed by an agent or the CLI). Only users have
#   slugged pages.
class Page < ApplicationRecord
  MAX_CUSTOM_HTML_LENGTH = 500_000
  MAX_CONTENT_LENGTH = 500_000
  MAX_TITLE_LENGTH = 255
  MAX_SLUG_LENGTH = 100

  # Slugs serve at the root of the username subdomain and custom domains, so
  # they must never shadow a path those domains already route. Keep this list
  # aligned with the storefront routes in config/routes.rb (root-domain
  # `/:username/...` routes and the UserCustomDomainConstraint block).
  RESERVED_SLUGS = %w[
    affiliate_requests affiliates braintree checkout coffee confirm confirm-redirect
    consumption_analytics d edit follow integrations l landing library media_locations
    p pages posts posts_paginated product_reviews products purchases r read s
    save_to_library signup subscribe subscribe_preview updates wishlists zip
  ].freeze

  belongs_to :pageable, polymorphic: true, touch: true

  validates :custom_html, length: { maximum: MAX_CUSTOM_HTML_LENGTH }
  validates :content, length: { maximum: MAX_CONTENT_LENGTH }

  with_options if: :slugged? do
    validates :title, presence: true, length: { maximum: MAX_TITLE_LENGTH }
    validates :slug, length: { maximum: MAX_SLUG_LENGTH },
                     format: { with: /\A[a-z0-9]+(-[a-z0-9]+)*\z/, message: "can only contain lowercase letters, numbers, and hyphens" },
                     exclusion: { in: RESERVED_SLUGS, message: "is reserved" },
                     uniqueness: { scope: [:pageable_type, :pageable_id] }
    validates :pageable_type, inclusion: { in: %w[User], message: "can't have slugged pages" }
  end

  # MySQL unique indexes allow multiple NULLs, so the one-root-page-per-owner
  # rule has to live here rather than in the index.
  validate :only_one_root_page, unless: :slugged?

  # Safety net so every save path (internal dashboard, API v2, model writes)
  # ends up sanitized. The API v2 controller still calls sanitize_with_report
  # ahead of time so it can return the report; that's idempotent with this.
  before_save :sanitize_html

  scope :roots, -> { where(slug: nil) }
  scope :slugged, -> { where.not(slug: nil) }

  # The root page is the whole-surface custom HTML takeover; slugged pages are
  # the first-class Pages entries that hang off the storefront at /<slug>.
  def slugged?
    slug.present?
  end

  def to_param
    slug
  end

  private
    def sanitize_html
      self.custom_html = custom_html.nil? ? nil : Ai::PageSanitizer.sanitize(custom_html).presence
      self.content = content.nil? ? nil : Pages::RichContentSanitizer.sanitize(content)
    end

    def only_one_root_page
      scope = Page.roots.where(pageable_type:, pageable_id:)
      scope = scope.where.not(id:) if persisted?
      errors.add(:slug, "can't be blank — this account already has a root page") if scope.exists?
    end
end
