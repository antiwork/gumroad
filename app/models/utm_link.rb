# frozen_string_literal: true

class UtmLink < ApplicationRecord
  include Deletable, ExternalId

  MAX_UTM_PARAM_LENGTH = 200

  has_paper_trail

  belongs_to :seller, class_name: "User"
  belongs_to :target_resource, polymorphic: true, optional: true

  has_many :utm_link_visits, dependent: :destroy
  has_many :utm_link_driven_sales, dependent: :destroy
  has_many :purchases, through: :utm_link_driven_sales
  has_many :successful_purchases,
           -> { successful_or_preorder_authorization_successful_and_not_refunded_or_chargedback },
           through: :utm_link_driven_sales,
           class_name: "Purchase",
           source: :purchase

  enum :target_resource_type, {
    profile_page: "profile_page",
    subscribe_page: "subscribe_page",
    product_page: "product_page",
    post_page: "post_page"
  }, prefix: :target, validate: true

  before_validation :set_permalink

  validates :title, presence: true
  validates :target_resource_id, presence: true, if: :requires_resource_id?
  validates :permalink, presence: true, format: { with: /\A[a-z0-9]{8}\z/ }, uniqueness: { case_sensitive: false }
  validates :utm_campaign, presence: true, length: { maximum: MAX_UTM_PARAM_LENGTH }
  validates :utm_medium, presence: true, length: { maximum: MAX_UTM_PARAM_LENGTH }
  validates :utm_source, presence: true, length: { maximum: MAX_UTM_PARAM_LENGTH }
  validates :utm_term, length: { maximum: MAX_UTM_PARAM_LENGTH }
  validates :utm_content, length: { maximum: MAX_UTM_PARAM_LENGTH }
  validate :last_click_at_is_same_or_after_first_click_at
  validate :utm_fields_are_unique_per_target_resource

  scope :enabled, -> { where(disabled_at: nil) }
  scope :active, -> { alive.enabled }

  def enabled? = disabled_at.blank?

  def active? = alive? && enabled?

  def mark_disabled!
    update!(disabled_at: Time.current)
  end

  def mark_enabled!
    update!(disabled_at: nil)
  end

  def short_url
    "#{UrlService.short_domain_with_protocol}/u/#{permalink}"
  end

  def utm_url
    uri = Addressable::URI.parse(target_resource_url)
    params = uri.query_values || {}
    params["utm_source"] = utm_source
    params["utm_medium"] = utm_medium
    params["utm_campaign"] = utm_campaign
    params["utm_term"] = utm_term if utm_term.present?
    params["utm_content"] = utm_content if utm_content.present?
    uri.query_values = params
    uri.to_s
  end

  def target_resource_name
    if target_product_page?
      "Product — #{target_resource.name}"
    elsif target_post_page?
      "Post — #{target_resource.name}"
    elsif target_profile_page?
      "Profile page"
    elsif target_subscribe_page?
      "Subscribe page"
    end
  end

  def default_title
    "#{target_resource_name} (auto-generated)".strip
  end

  def self.generate_permalink(max_retries: 10)
    retries = 0
    candidate = SecureRandom.alphanumeric(8).downcase

    while self.exists?(permalink: candidate)
      retries += 1
      raise "Failed to generate unique permalink after #{max_retries} attempts" if retries >= max_retries

      candidate = SecureRandom.alphanumeric(8).downcase
    end

    candidate
  end

  # Overrides the polymorphic class for :target_resource association since we
  # don't store the actual class names in the :target_resource_type column
  def self.polymorphic_class_for(name)
    case name.to_s
    when target_resource_types[:post_page] then Installment
    when target_resource_types[:product_page] then Link
    end
  end

  private
    def requires_resource_id?
      target_product_page? || target_post_page?
    end

    def last_click_at_is_same_or_after_first_click_at
      return if last_click_at.blank?

      if first_click_at.nil? || first_click_at > last_click_at
        errors.add(:last_click_at, "must be same or after the first click at")
      end
    end

    def target_resource_url
      if target_profile_page?
        seller.profile_url
      elsif target_subscribe_page?
        Rails.application.routes.url_helpers.custom_domain_subscribe_url(host: seller.subdomain_with_protocol)
      elsif target_product_page?
        target_resource.long_url
      elsif target_post_page?
        target_resource.full_url
      end
    end

    def set_permalink
      return if permalink.present?

      self.permalink = self.class.generate_permalink
    end

    def utm_fields_are_unique_per_target_resource
      return if self.class.alive.where(
        seller_id:,
        utm_source:,
        utm_medium:,
        utm_campaign:,
        utm_term:,
        utm_content:,
        target_resource_type:,
        target_resource_id:
      ).where.not(id:).none?

      errors.add(:target_resource_id, "A link with similar UTM parameters already exists for this destination!")
    end
end
