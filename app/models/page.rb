# frozen_string_literal: true

class Page < ApplicationRecord
  include Deletable
  include TimestampScopes
  include ExternalId

  belongs_to :user
  belongs_to :link, optional: true
  belongs_to :published_version, class_name: "PageVersion", optional: true
  has_many :page_versions, dependent: :destroy

  validates :title, presence: true, length: { maximum: 255 }
  validates :slug, presence: true, length: { maximum: 100 },
                   format: { with: /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/, message: "can only contain lowercase letters, numbers, and hyphens" }
  validates :slug, uniqueness: { scope: :user_id, conditions: -> { alive } }
  validates :html_content, length: { maximum: 500_000 }
  validates :is_profile, uniqueness: { scope: :user_id, conditions: -> { alive.where(is_profile: true) }, message: "already exists for this user" }, if: :is_profile?

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
    resolved_html = target&.html || html_content
    if resolved_html.blank?
      errors.add(:base, "Generate the page before publishing it.")
      raise ActiveRecord::RecordInvalid, self
    end

    attrs = {
      published: true,
      published_at: Time.current,
      published_version: target,
    }
    attrs[:html_content] = resolved_html if version.nil?
    update!(attrs)
  end

  def unpublish!
    update!(published: false)
  end

  def latest_version
    page_versions.order(created_at: :desc).first
  end

  def apply_new_version!(version)
    update!(
      html_content: version.html,
      published_version: (auto_publish ? version : published_version),
      published: (auto_publish ? true : published),
      published_at: (auto_publish ? Time.current : published_at),
    )
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

  private
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
