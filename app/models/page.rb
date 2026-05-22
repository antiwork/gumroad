# frozen_string_literal: true

class Page < ApplicationRecord
  include Deletable
  include TimestampScopes
  include ExternalId

  belongs_to :user
  belongs_to :link, optional: true
  belongs_to :published_version, class_name: "PageVersion", optional: true
  has_many :page_versions, dependent: :destroy

  DEFAULT_TITLE = "Untitled page"

  validates :title, length: { maximum: 255 }
  validates :slug, presence: true, length: { maximum: 100 },
                   format: { with: /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/, message: "can only contain lowercase letters, numbers, and hyphens" }
  validates :slug, uniqueness: { scope: :user_id, conditions: -> { alive } }
  validates :html_content, length: { maximum: 500_000 }
  validates :is_profile, uniqueness: { scope: :user_id, conditions: -> { alive.where(is_profile: true) }, message: "already exists for this user" }, if: :is_profile?
  # A page must belong to exactly one owner — a product (link_id) or the
  # seller's profile (is_profile=true). Standalone pages are no longer
  # supported; pages are surfaced via the "Customize" button on a product
  # or profile, never as a top-level resource.
  validate :must_have_owner

  # Title is a creator-facing label, not a required input; default it so the
  # DB NOT NULL constraint never forces callers to invent a placeholder.
  before_validation :default_title, on: :create
  before_validation :generate_slug, on: :create

  scope :published, -> { where(published: true) }
  scope :draft, -> { where(published: false) }

  # When promoting an explicit older version, the caller's working draft in
  # html_content stays put — only published_version flips. The public view
  # serves published_version.html (see PageViewsController), so the draft a
  # creator is iterating on isn't displaced from the editor.
  #
  # When publishing without a target (auto-publish or "publish latest"), we
  # mirror the resolved html onto html_content so the model's current state
  # matches what's published.
  def publish!(version: nil)
    target = version || latest_version
    # Refuse to mark a page published unless we have a concrete version to
    # pin. Without a version, the public view has nothing safe to serve and
    # would otherwise leak the seller's editor draft from html_content.
    if target.nil?
      errors.add(:base, "Generate the page before publishing it.")
      raise ActiveRecord::RecordInvalid, self
    end

    attrs = {
      published: true,
      published_at: Time.current,
      published_version: target,
    }
    attrs[:html_content] = target.html if version.nil?
    update!(attrs)
  end

  def unpublish!
    update!(published: false)
  end

  def latest_version
    page_versions.order(created_at: :desc).first
  end

  # Applies a generated version onto the page. `expected_parent_id` is the
  # version the calling job was branched off at enqueue time; if a newer
  # version has been applied in the meantime, we'd otherwise silently
  # overwrite that work with this stale generation. The check runs inside
  # `with_lock` so two concurrent applies can't both pass the comparison.
  # Returns true if the version was applied, false if it was skipped as stale.
  def apply_new_version!(version, expected_parent_id: nil)
    with_lock do
      if expected_parent_id
        current_parent = page_versions.where.not(id: version.id).order(created_at: :desc).first&.id
        return false if current_parent && current_parent != expected_parent_id
      end

      update!(
        html_content: version.html,
        published_version: (auto_publish ? version : published_version),
        published: (auto_publish ? true : published),
        published_at: (auto_publish ? Time.current : published_at),
      )
      true
    end
  end

  def page_url(host: nil)
    # Prefer the seller's custom subdomain when configured (matches
    # custom_domain_view_page in config/routes.rb). Falls back to the
    # username-scoped public route on the canonical app host so the URL is
    # always non-empty — clients can copy/share it even for sellers without
    # a subdomain configured.
    if host
      "#{host}/pages/#{slug}"
    elsif user&.subdomain_with_protocol.present?
      "#{user.subdomain_with_protocol}/pages/#{slug}"
    else
      "#{PROTOCOL}://#{DOMAIN}/#{user.username}/pages/#{slug}"
    end
  end

  # Free up the slug for reuse when soft-deleting. Truncate the base so the
  # `-deleted-#{id}` suffix can't push the slug past the 100-char validation.
  def mark_deleted!
    suffix = "-deleted-#{id}"
    base = slug.to_s.first(100 - suffix.length)
    self.slug = "#{base}#{suffix}"
    super
  end

  # generate_slug picks a free slug with a read-then-write check, which is a
  # TOCTOU: two concurrent inserts with the same title both resolve to the
  # same candidate before either has persisted. The unique index catches the
  # collision; this rescue/retry regenerates with a fresh counter so the
  # second create transparently lands on slug-1, slug-2, etc.
  SLUG_RETRY_LIMIT = 3
  private_constant :SLUG_RETRY_LIMIT

  def create_or_update(...)
    attempts = 0
    begin
      super
    rescue ActiveRecord::RecordNotUnique => e
      raise unless new_record?
      raise unless e.message.to_s.include?("index_pages_on_user_id_and_slug")
      attempts += 1
      raise if attempts > SLUG_RETRY_LIMIT
      # Re-run the slug picker; the row that won the race is now visible to
      # generate_slug's existence query, so it picks the next free counter
      # value instead of repeating the collision.
      self.slug = nil
      send(:generate_slug)
      retry
    end
  end

  private
    def must_have_owner
      return if link_id.present? || is_profile?
      errors.add(:base, "Page must belong to a product or profile")
    end

    def default_title
      return if title.present?
      self.title = link&.name.presence&.first(255) || DEFAULT_TITLE
    end

    def generate_slug
      return if slug.present?
      base = title.to_s.parameterize.first(80)
      base = "page" if base.blank?
      candidate = base
      counter = 1
      while user && Page.alive.where(user_id: user_id, slug: candidate).exists?
        candidate = "#{base}-#{counter}"
        counter += 1
      end
      self.slug = candidate
    end
end
