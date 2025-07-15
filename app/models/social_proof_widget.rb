# frozen_string_literal: true

class SocialProofWidget < ApplicationRecord
  attribute :icon_color, :string
  include ExternalId
  include Deletable
  include ActionView::Helpers::DateHelper

  has_one_attached :custom_image

  has_and_belongs_to_many :products,
                          class_name: "Link",
                          join_table: "social_proof_widgets_products",
                          association_foreign_key: "product_id"

  has_many :attributed_purchases, foreign_key: :widget_id, primary_key: :external_id, class_name: 'Purchase'

  belongs_to :user

  enum cta_type: {
    button: 0,
    link: 1,
    none: 2
  }, _prefix: true

  enum status: {
    published: 0,
    unpublished: 1
  }, _prefix: true

  # constants
  IMAGE_TYPES = %w[none product_thumbnail custom_image].freeze
  ICON_TYPES = %w[
    solid-star heart-fill solid-check-circle cart3-fill
    people-fill gift-fill solid-currency-dollar clock-history
    lightning-fill solid-sparkles
  ].freeze

  IMAGE_TYPES.each do |type|
    const_set("IMAGE_TYPE_#{type.upcase}", type)
  end

  # validations
  validates :name, presence: true, length: { maximum: 255 }
  validates :cta_type, presence: true
  validates :image_type, inclusion: { in: -> { all_image_types } }
  validates :user, presence: true
  validate :custom_image_present_when_required
  validate :universal_widgets_cannot_have_specific_products
  validate :non_universal_widgets_must_have_products

  # scopes
  scope :universal, -> { where(universal: true) }
  scope :for_product, -> (product) {
    published.alive.left_joins(:products).where(
      "social_proof_widgets.universal = ? OR links.id = ?", 
      true, 
      product.id
    )
  }
  scope :published, -> { where(status: :published) }
  scope :unpublished, -> { where(status: :unpublished) }

  def self.all_image_types
    IMAGE_TYPES + ICON_TYPES.map { |icon| "icon_#{icon}" }
  end

  def self.icon_types
    ICON_TYPES.map { |icon| "icon_#{icon}" }
  end

  def is_icon?
    image_type.start_with?("icon_")
  end

  def icon_name
    image_type.sub(/^icon_/, '') if is_icon?
  end

  def applicable_products(user)
    if universal?
      user.links.alive
    else
      products.alive
    end
  end

  def image_url(product = nil)
    case image_type
    when "product_thumbnail"
      product&.thumbnail_alive&.url
    when "custom_image"
      custom_image.attached? ? custom_image.url : nil
    when /^icon_/
      nil
    end
  end

  def as_json(options = {})
    {
      id: external_id,
      name: name,
      universal: universal?,
      title: title,
      description: description,
      cta_text: cta_text,
      cta_type: cta_type,
      image_type: image_type,
      image_url: image_url,
      icon_color: icon_color,
      products: universal? ? [] : products.map(&:external_id),
      status: status,
      user_id: user.external_id
    }
  end

  def as_json_for_product(product)
    {
      id: external_id,
      name: name,
      title: rendered_title(product: product),
      description: rendered_description(product: product),
      cta_text: cta_text,
      cta_type: cta_type,
      image_url: image_url(product),
      image_type: image_type,
      icon_name: icon_name,
      icon_color: icon_color
    }
  end
  
  def render_content(field, product:)
    content = self.send(field) # title or description
    return content if content.blank?
  
    Rails.logger.debug "Original content: #{content}"
    Rails.logger.debug "Product: #{product.name} (ID: #{product.id})"
    
    substitutions = build_substitutions(product)
    Rails.logger.debug "Substitutions: #{substitutions}"
  
    rendered_content = content.dup
    substitutions.each { |key, value| rendered_content.gsub!(key, value.to_s) }
    Rails.logger.debug "Rendered content: #{rendered_content}"
    rendered_content
  end

  def rendered_title(product:)
    render_content(:title, product: product)
  end

  def rendered_description(product:)
    render_content(:description, product: product)
  end

  # increment counters
  def increment_conversion!(amount_cents)
    SocialProofWidget.where(id: id).update_all([
      "conversions_count = conversions_count + 1, revenue_cents = revenue_cents + ?", amount_cents
    ])
  end

  # analytics methods
  def conversion_rate
    return 0.0 if clicks_count.zero?
    (conversions_count.to_f / clicks_count).round(4)
  end
  
  def attributed_revenue_cents
    revenue_cents
  end
  
  def analytics_summary
    {
      impressions: impressions_count,
      clicks: clicks_count,
      dismissals: dismissals_count,
      conversions: conversions_count,
      conversion_rate: conversion_rate,
      revenue_cents: revenue_cents,
    }
  end

  PLACEHOLDER_COUNT = 17

  private

  def build_substitutions(product)
    recent_purchases = product.sales.successful
                              .includes(:purchaser)
                              .limit(5)
                              .order(created_at: :desc)

    sales_count = product.sales.successful.count
    customers_count = product.sales.successful.distinct.count(:purchaser_id)

    {
        "[total_sales]" => sales_count > 0 ? sales_count : PLACEHOLDER_COUNT,
        "[product_name]" => product.name,
        "[recent_buyers]" => recent_buyer_names(recent_purchases),
        "[total_customers]" => customers_count > 0 ? customers_count : PLACEHOLDER_COUNT,
        "[last_purchase_time]" => recent_purchases.first&.created_at ? time_ago_in_words(recent_purchases.first.created_at) : "1 day ago",
        "[seller_name]" => product.user.name_or_username
    }
  end

  def recent_buyer_names(purchases)
    names = purchases.limit(3).map { |p| p.purchaser&.first_name || "Someone" }
    case names.size
    when 0
      "customers"
    when 1
      names.first
    when 2
      "#{names.first} and #{names.second}"
    else
      "#{names.first}, #{names.second}, and #{names.size - 2} others"
    end
  end

  def custom_image_present_when_required
    if image_type == "custom_image" && !custom_image.attached?
      errors.add(:custom_image, "must be attached when image type is custom image")
    end
  end

  def universal_widgets_cannot_have_specific_products
    if universal? && products.any?
      errors.add(:base, "Universal widgets cannot be assigned to specific products")
    end
  end

  def non_universal_widgets_must_have_products
    if !universal? && products.empty?
        errors.add(:base, "Non-universal widgets must be assigned to at least one product")
    end
  end

end