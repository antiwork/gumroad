# frozen_string_literal: true

class Checkout::SocialProofWidgetPresenter
  include Rails.application.routes.url_helpers
  include ActionView::Helpers::DateHelper

  attr_reader :widget, :current_user

  def initialize(widget:, current_user: nil)
    @widget = widget
    @current_user = current_user
  end

  def listing_props
    {
      id: widget.external_id,
      name: widget.name,
      universal: widget.universal?,
      cta_type: widget.cta_type,
      image_type: widget.image_type,
      product_count: widget.universal? ? 0 : widget.products.alive.count,
      status: widget.status,
      created_at: widget.created_at.iso8601,
      updated_at: widget.updated_at.iso8601
    }
  end

  def edit_props
    {
      id: widget.external_id,
      name: widget.name || "",
      universal: widget.universal?,
      title: widget.title || "",
      description: widget.description || "",
      cta_text: widget.cta_text || "",
      cta_type: widget.cta_type,
      image_type: widget.image_type || "product_thumbnail",
      custom_image_url: widget.custom_image.attached ? widget.custom_image.url : nil,
      product_ids: widget.universal? ? [] : widget.products.alive.map(&:external_id),
      status: widget.status,
      available_products: available_products_for_selection,
      image_type_options: self.image_type_options,
      cta_type_options: self.cta_type_options,
      icon_options: self.icon_options
    }
  end

  def display_props(product:)
    return nil unless widget.applicable_products(current_user).include?(product)

    widget.as_json_for_product(product)
  end

  def self.listing_props_collection(widgets:, current_user: nil)
    widgets.map do |widget|
      new(widget: widget, current_user: current_user).listing_props
    end
  end

  def self.widgets_for_product(product:, current_user: nil)
    applicable_widgets = SocialProofWidget.published.for_product(product)
                                          .includes(:products, custom_image_attachment: :blob)

    applicable_widgets.filter_map do |widget|
      presenter = new(widget: widget, current_user: current_user)
      presenter.display_props(product: product)
    end
  end

  private

  def available_products_for_selection
    return [] unless current_user
    
    current_user.links.alive.order(:name).map do |product|
      {
        id: product.external_id,
        name: product.name,
        thumbnail_url: product.thumbnail&.alive&.url
      }
    end
  end

  def self.image_type_options
    [
      { value: "none", label: "No Image" },
      { value: "product_thumbnail", label: "Product Thumbnail" },
      { value: "custom_image", label: "Custom Image" },
      { value: "icon", label: "Icon" }
    ]
  end

  def self.cta_type_options
    SocialProofWidget.cta_types.map do |key, value|
      { value: key, label: key.humanize }
    end
  end

  def self.icon_options
    SocialProofWidget::ICON_TYPES.map do |icon|
      { value: icon, label: self.icon_label(icon) }
    end
  end

  def self.icon_label(icon)
    case icon
    when "solid-star" then "Star"
    when "heart-fill" then "Heart"
    when "solid-check-circle" then "Check Badge"
    when "cart3-fill" then "Shopping Cart"
    when "people-fill" then "Users"
    when "gift-fill" then "Gift"
    when "solid-currency-dollar" then "Dollar"
    when "clock-history" then "Clock"
    when "lightning-fill" then "Lightning"
    when "solid-sparkles" then "Sparkles"
    else
      icon.humanize
    end
  end

end