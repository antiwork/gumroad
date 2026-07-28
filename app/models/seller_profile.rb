# frozen_string_literal: true

class SellerProfile < ApplicationRecord
  FONT_CHOICES = ["ABC Favorit", "Inter", "Domine", "Merriweather", "Roboto Slab", "Roboto Mono"]

  belongs_to :seller, class_name: "User"

  validates :font, inclusion: { in: FONT_CHOICES }
  validates :background_color, hex_color: true
  validates :highlight_color, hex_color: true
  validate :validate_json_data, if: -> { self[:json_data].present? }

  after_save :clear_custom_style_cache, if: -> { %w[highlight_color background_color font].any? { |prop| send(:"saved_change_to_#{prop}?") } }

  after_initialize do
    self.font ||= "ABC Favorit"
    self.background_color ||= "#ffffff"
    self.highlight_color ||= "#ff90e8"
  end

  # Version stamp for optimistic concurrency in the pages/sections editor: the most recent change
  # to either the tab layout (this record) or any on-profile section row. Section edits write the
  # section rows rather than this record, so the section timestamps must be folded in too — without
  # them a concurrent section-content edit could pass the editor's stale-save check unnoticed.
  def layout_version
    [updated_at, seller.seller_profile_sections.on_profile.maximum(:updated_at)].compact.max
  end

  def custom_styles
    Rails.cache.fetch(custom_style_cache_name) do
      component_path = File.read(Rails.root.join("app", "views", "layouts", "custom_styles", "styles.scss.erb"))
      sass = ERB.new(component_path).result(binding)

      SassC::Engine.new(
        sass,
        syntax: :scss,
        read_cache: false,
        cache: false,
        style: :compressed,
        ).render
    end
  end

  # The text colour that goes on top of the seller's accent colour (pay button, offer banner
  # price, and anything else using --contrast-accent). Picked by actual contrast rather than by
  # a lightness threshold — see ContrastColor for why that distinction matters.
  def text_color_on_highlight
    ContrastColor.for(highlight_color)
  end

  # The text colour for body copy sitting directly on the seller's background colour.
  def text_color_on_background
    ContrastColor.for(background_color)
  end

  # --primary is the body text colour, so --contrast-primary is what sits on top of *it*: the
  # readable colour against the body text colour, which is what a filled primary button needs.
  def text_color_on_primary
    ContrastColor.for(text_color_on_background)
  end

  def font_family
    fallback = case font
               when "Domine", "Merriweather", "Roboto Slab"
                 "serif"
               when "Roboto Mono"
                 "monospace"
               else
                 "sans-serif"
    end
    %("#{font}", "ABC Favorit", #{fallback})
  end

  def custom_style_cache_name
    # Bumped to v3 when the text-colour choice moved from HSL lightness to WCAG contrast. Without
    # the bump, sellers with already-cached CSS would keep being served the old unreadable colour.
    "users/#{seller.id}/custom_styles_v3"
  end

  def validate_json_data
    # slice away the "in schema [id]" part that JSON::Validator otherwise includes
    json_validator.validate(json_data).each { errors.add(:base, _1[..-48]) }
  end

  def json_validator
    json_schema = JSON.parse(File.read(Rails.root.join("lib", "json_schemas", "seller_profile.json").to_s))
    @__json_validator ||= JSON::Validator.new(json_schema, insert_defaults: true, record_errors: true)
  end

  def json_data
    self[:json_data] ||= {}
    super
  end

  private
    def clear_custom_style_cache
      Rails.cache.delete custom_style_cache_name
    end
end
