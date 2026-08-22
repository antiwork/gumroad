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
  # Set on the candidate the dry-run preview endpoints validate (never saved),
  # so moderation reports the verdict to the caller without recording an admin
  # note about a page that was never published.
  attr_accessor :moderation_preview

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

  # Only on a content change: a page is touched by unrelated saves (a slug
  # rename, a `touch` from its owner) and re-moderating those would spend a
  # model call to re-read text that already passed.
  validate :content_moderation_check, if: -> { custom_html_changed? || content_changed? || title_changed? }

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

  # The owning seller. A page hangs off a user (their storefront) or a product
  # (its landing page takeover). Public because the moderation extractor and
  # service both need it, and three copies of the expression would mean a future
  # pageable type has to be remembered in three places.
  def seller
    pageable.is_a?(User) ? pageable : pageable.try(:user)
  end

  private
    def sanitize_html
      self.custom_html = custom_html.nil? ? nil : Ai::PageSanitizer.sanitize(custom_html).presence
      self.content = content.nil? ? nil : Pages::RichContentSanitizer.sanitize(content)
    end

    # Runs on the HTML as submitted, before `sanitize_html` rewrites it: what a
    # page SAYS is unchanged by sanitization. This reads the submitted document
    # on the slugged-pages API and the dashboard (which assign raw input), so
    # text hidden in a tag the sanitizer would have dropped is still seen; the
    # root-page writers (Pages::CustomHtmlWriter, the products API) assign
    # already-sanitized HTML, so there moderation and the previews agree.
    def content_moderation_check
      return if seller&.vip_creator?
      # Taking a page DOWN is never a publish, so it must not depend on the
      # moderation service being reachable — otherwise an OpenAI outage stops a
      # seller removing the very copy that got them flagged. The extractor's
      # "Title: " prefix means a blanked page is not blank text, so the service's
      # own blank short-circuit can't cover this. A slugged page left with only a
      # title is still published (the title renders in the page list), so it is
      # still moderated.
      return if custom_html.blank? && content.blank? && title.blank?

      # A title-only save cannot introduce or remove an image, so it moderates the
      # text and leaves the images alone. Without this a rename re-runs the whole
      # image phase, and on a page that predates the image budget it is rejected
      # for a size it is not changing — trapping the rename on a page that is
      # already live.
      images_unchanged = persisted? && !custom_html_changed? && !content_changed?
      result = ContentModeration::ModerateRecordService.check(self, :page, skip_images: images_unchanged)
      return if result.passed

      # On :base, like products and posts: the message is a whole sentence naming
      # the page, so an attribute prefix from `full_message` would read wrong.
      # The dry-run preview endpoints therefore have to read :base too, or a page
      # the real write rejects would preview as publishable.
      errors.add(:base, ContentModeration::ModerateRecordService.seller_message(result.reasons, "page", title: title))
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
