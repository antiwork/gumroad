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
  #
  # "profile" is reserved for a different reason: the pages management UI uses
  # /pages/profile as the special entry for the seller's pinned profile page
  # (see PagesController#set_page), so a real page with that slug would be
  # unreachable from the UI.
  RESERVED_SLUGS = %w[
    affiliate_requests affiliates braintree checkout coffee confirm confirm-redirect
    consumption_analytics d edit follow integrations l landing library media_locations
    p pages posts posts_paginated product_reviews products profile purchases r read s
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

  # Builds a URL slug from a page title, shared by the management UI and the
  # API so both create paths follow the same rules: parameterize the title,
  # fall back to "page" when the title has no URL-safe characters, and append
  # a number when the slug is already taken (or reserved) for this owner.
  #
  # Titles can be up to MAX_TITLE_LENGTH (255) characters while slugs max out
  # at MAX_SLUG_LENGTH (100), so the base is truncated before any collision
  # checks — otherwise a long-but-valid title would generate a slug the length
  # validation rejects and the create would fail instead of succeeding.
  def self.generate_slug_for(owner, title)
    base = title.to_s.parameterize
    base = "page" if base.blank?
    base = truncate_slug(base, MAX_SLUG_LENGTH)
    return base unless slug_taken_for?(owner, base)

    (2..).each do |n|
      suffix = "-#{n}"
      # Re-truncate so the numbered candidate also fits within the limit even
      # when the base already uses the full length.
      candidate = truncate_slug(base, MAX_SLUG_LENGTH - suffix.length) + suffix
      return candidate unless slug_taken_for?(owner, candidate)
    end
  end

  def self.slug_taken_for?(owner, slug)
    RESERVED_SLUGS.include?(slug) || owner.pages.exists?(slug:)
  end

  # Cuts a slug down to `max` characters without leaving a trailing hyphen
  # (the slug format validation rejects trailing hyphens, and a cut can land
  # in the middle of a word boundary like "my-long-...-").
  def self.truncate_slug(slug, max)
    slug[0, max].sub(/-+\z/, "")
  end
  private_class_method :truncate_slug

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
      # `.lock` makes this a SELECT ... FOR UPDATE. A save wraps validation and
      # the INSERT in one transaction, so when two saves race to create a root
      # page for the same owner, both locking reads take gap locks on the
      # (pageable_type, pageable_id, slug) index range where the new row would
      # land. Gap locks coexist, but each INSERT then needs an insert intention
      # lock that conflicts with the other transaction's gap lock — InnoDB
      # detects the deadlock and aborts one transaction, so at most one root
      # page is created. This depends on the REPEATABLE READ isolation level
      # (our default); it exists because the database index can't enforce the
      # rule itself — MySQL unique indexes allow multiple NULL slugs (see above).
      errors.add(:slug, "can't be blank — this account already has a root page") if scope.lock.exists?
    end
end
