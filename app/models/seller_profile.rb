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

  # The accent colour to actually fill text-bearing accent areas with (pay button, offer banner
  # price, anything using --accent together with --contrast-accent), and the text colour to put on
  # it. Usually this is exactly what the seller saved; where their colour cannot carry either black
  # or white text at 4.5:1, its brightness is nudged by the smallest amount that clears the floor.
  # The saved highlight_color is never changed — see ContrastColor#accessible_accent for why the
  # adjustment happens at display time and how the text colour is chosen.
  def accessible_accent
    # Deliberately not memoized: the editor updates highlight_color on a live record and then reads
    # these colours back, so a cached pair would show the seller the colour they just replaced.
    ContrastColor.accessible_accent(highlight_color)
  end

  # The displayed accent for areas that carry text. Areas with no text on them keep the seller's
  # colour exactly as saved (--accent-plain in the storefront CSS).
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
    # Bumped to v4 when text-bearing accent areas started rendering a brightness-adjusted accent so
    # their text could clear 4.5:1 (v3 was the move from HSL lightness to WCAG contrast). Without the
    # bump, sellers with already-cached CSS would keep being served the old colour pair.
    "users/#{seller.id}/custom_styles_v4"
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
