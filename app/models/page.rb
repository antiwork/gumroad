# frozen_string_literal: true

class Page < ApplicationRecord
  include Deletable
  include TimestampScopes
  include ExternalId

  belongs_to :user
  belongs_to :link, optional: true
  has_many :page_versions, dependent: :destroy

  validates :title, presence: true, length: { maximum: 255 }
  validates :slug, presence: true, length: { maximum: 100 },
                   format: { with: /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/, message: "can only contain lowercase letters, numbers, and hyphens" }
  validates :slug, uniqueness: { scope: :user_id }
  validates :html_content, length: { maximum: 500_000 }
  validates :is_profile, uniqueness: { scope: :user_id, conditions: -> { alive.where(is_profile: true) }, message: "already exists for this user" }, if: :is_profile?

  before_validation :generate_slug, on: :create

  scope :published, -> { where(published: true) }
  scope :draft, -> { where(published: false) }

  def publish!
    update!(published: true, published_at: Time.current)
  end

  def unpublish!
    update!(published: false)
  end

  def latest_version
    page_versions.order(created_at: :desc).first
  end

  def page_url(host: nil)
    base = host || "#{Rails.application.config.short_url_host}"
    "#{base}/pages/#{slug}"
  end

  private
    def generate_slug
      return if slug.present?
      base = title.to_s.parameterize.first(80)
      base = "page" if base.blank?
      candidate = base
      counter = 1
      while user && Page.where(user_id: user_id, slug: candidate).exists?
        candidate = "#{base}-#{counter}"
        counter += 1
      end
      self.slug = candidate
    end
end
