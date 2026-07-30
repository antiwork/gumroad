# frozen_string_literal: true

class SellerProfile < ApplicationRecord
  FONT_CHOICES = ["ABC Favorit", "Inter", "Domine", "Merriweather", "Roboto Slab", "Roboto Mono"]
  DANGER_COLOR_CHOICES = ["#dc341e", "#9b1c12", "#ffb4ab"]

  def self.google_fonts_css_source(fonts)
    families = fonts.sort.map { "family=#{_1}:wght@400;600" }.join("&")
    Addressable::URI.encode("https://fonts.googleapis.com/css2?#{families}&display=swap")
  end

  def self.seller_fonts_css_source
    google_fonts_css_source(FONT_CHOICES.without("ABC Favorit"))
  end

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

  # Fingerprint only the pages/sections editor's state. Theme saves update this row too, so using
  # updated_at would falsely reject an otherwise current layout from another tab.
  def layout_version
    section_updated_at = seller.seller_profile_sections.on_profile.maximum(:updated_at)
    return if !persisted? && section_updated_at.nil?

    tabs = Array(json_data["tabs"]).map { [_1["name"], Array(_1["sections"])] }
    Digest::SHA256.hexdigest([tabs, section_updated_at&.iso8601(6)].to_json)
  end

  def custom_styles
    return "" unless custom_style_attributes_safe?

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

  # The accent colour to actually fill text-bearing accent areas with (pay button, offer banner
  # price, anything using --accent-with-text together with --contrast-accent), and the text colour
  # to put on it. Usually this is exactly what the seller saved; where their colour cannot carry
  # either black or white text at 4.5:1, its brightness is nudged by the smallest amount that clears
  # the floor.
  # The saved highlight_color is never changed — see ContrastColor#accessible_accent for why the
  # adjustment happens at display time and how the text colour is chosen.
  def accessible_accent
    # Deliberately not memoized: the editor updates highlight_color on a live record and then reads
    # these colours back, so a cached pair would show the seller the colour they just replaced.
    ContrastColor.accessible_accent(highlight_color)
  end

  # The displayed accent for areas that carry text. Every other use keeps the seller's saved colour
  # through --accent.
  def accent_color_for_text_areas
    accessible_accent[:accent]
  end

  # The text colour that goes on top of accent_color_for_text_areas.
  def text_color_on_highlight
    accessible_accent[:text]
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

  def danger_color
    DANGER_COLOR_CHOICES.find do |color|
      ContrastColor.ratio_between(color, background_color).to_f >= ContrastColor::WCAG_AA_NORMAL_TEXT
    end || text_color_on_background
  end

  # Keep Stripe's state indicators visible without changing the seller's saved accent.
  def accent_color_for_indicators
    ContrastColor.visible_indicator(highlight_color, background_color)
  end

  def text_color_on_danger
    ContrastColor.for(danger_color)
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

  def font_css_source
    return if font == "ABC Favorit"

    self.class.google_fonts_css_source([font])
  end

  def custom_style_cache_name
    # v5 invalidated CSS compiled before persisted style values were checked as a complete string.
    # Without the bump, a previously cached injection could outlive a repaired database row.
    "users/#{seller.id}/custom_styles_v5"
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
    def custom_style_attributes_safe?
      HexColorValidator.safe_for_css?(highlight_color) &&
        HexColorValidator.safe_for_css?(background_color) &&
        font.in?(FONT_CHOICES)
    end

    def clear_custom_style_cache
      Rails.cache.delete custom_style_cache_name
    end
end
