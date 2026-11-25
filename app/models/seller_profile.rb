# frozen_string_literal: true

class SellerProfile < ApplicationRecord
  include CdnUrlHelper

  FONT_CHOICES = ["ABC Favorit", "Inter", "Domine", "Merriweather", "Roboto Slab", "Roboto Mono"]
  DANGER_COLOR_CHOICES = ["#dc341e", "#9b1c12", "#ffb4ab"]
  # "medium" matches Gumroad's stock radius. Checkout also passes these values to Stripe's
  # Appearance API, which cannot read CSS variables, so keep them literal lengths.
  BORDER_RADIUS_CHOICES = { "none" => "0rem", "small" => "0.25rem", "medium" => "0.5rem", "large" => "1rem" }.freeze
  BUTTON_HOVER_OFFSETS = { "lift" => "0.25rem", "none" => "0rem" }.freeze
  # Border strength as an alpha of the store's text colour: the app's light-mode hairline under
  # dark text, its dark-mode hairline under light text. Mirrored by getStoreBorderAlpha in color.ts.
  BORDER_ALPHAS = { ContrastColor::BLACK => "0.11", ContrastColor::WHITE => "0.35" }.freeze
  # The app's own field-border alphas in light and dark mode. A store never goes below them.
  CONTROL_BORDER_ALPHA_FLOORS = { ContrastColor::BLACK => 0.45, ContrastColor::WHITE => 0.5 }.freeze
  STOCK_BACKGROUND = "#ffffff"
  # The app's own page colour, which is also the page behind an email's white card.
  STOCK_PAGE_BACKGROUND = "#f4f4f0"
  ALLOWED_SHARE_IMAGE_CONTENT_TYPES = ["image/png", "image/jpeg", "image/jpg"].freeze
  MAXIMUM_SHARE_IMAGE_FILE_SIZE = 5.megabytes

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
  validates :border_radius, inclusion: { in: BORDER_RADIUS_CHOICES.keys }
  validates :button_hover, inclusion: { in: BUTTON_HOVER_OFFSETS.keys }
  validate :validate_json_data, if: -> { self[:json_data].present? }

  # The home page's search listing. Same limits as a storefront page's.
  normalizes :seo_title, :seo_description, with: -> { _1.squish.presence }
  validates :seo_title, length: { maximum: Page::MAX_SEO_TITLE_LENGTH }
  validates :seo_description, length: { maximum: Page::MAX_SEO_DESCRIPTION_LENGTH }

  # The storefront share image, served ahead of the generated subscribe card.
  # Kept small: every crawl of the profile fetches it.
  has_one_attached :share_image
  validate :share_image_is_valid, if: -> { share_image.attached? && share_image.new_record? }

  before_validation :normalize_colors
  after_commit :clear_custom_style_cache, if: -> { %w[highlight_color background_color font border_radius button_hover].any? { |prop| send(:"saved_change_to_#{prop}?") } }

  after_initialize do
    self.font ||= "ABC Favorit"
    self.background_color ||= STOCK_BACKGROUND
    self.highlight_color ||= "#ff90e8"
    self.border_radius ||= "medium"
    self.button_hover ||= "none"
  end

  # Fingerprint only the pages/sections editor's state. Theme saves update this row too, so using
  # updated_at would falsely reject an otherwise current layout from another tab.
  def layout_version
    section_updated_at = seller.seller_profile_sections.on_profile.maximum(:updated_at)
    tabs = Array(json_data["tabs"]).map { [_1["name"], Array(_1["sections"])] }
    Digest::SHA256.hexdigest([tabs, section_updated_at&.iso8601(6)].to_json)
  end

  # The share image as a CDN URL, or nil when the seller has not uploaded one.
  # Deliberately nil rather than a placeholder: `avatar_url` always resolves, so
  # a caller must be able to tell "no seller image" from "no image at all".
  def share_image_url
    cdn_url_for(share_image.url) if share_image.attached?
  rescue => e
    Rails.logger.warn("SellerProfile#share_image_url error (#{id}): #{e.class} => #{e.message}")
    nil
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

  # Email clients cannot read the CSS variables in custom_styles, so filled email buttons get the
  # accent as literal colours.
  # The border is the accent itself unless that has vanished into the surface behind the button.
  # mso-border-alt repeats it for Outlook on Windows, where the button's padding is drawn as a
  # border (see `.button.primary` in the email stylesheet).
  def email_primary_button_style(surface: background_color)
    colors = accessible_accent
    border = ContrastColor.visible_indicator(colors[:accent], surface)
    "background-color: #{colors[:accent]}; color: #{colors[:text]}; border-color: #{border}; mso-border-alt: solid #{border} 8pt;"
  end

  # The theme again, for the post's own wrapper: a client that drops <body> (a forward, some Android
  # apps) would otherwise show a dark theme's white wordmark and buttons on a white page.
  def email_body_style
    return "" unless HexColorValidator.safe_for_css?(background_color)

    "background-color: #{background_color}; color: #{text_color_on_background}; font-family: #{font_family.tr('"', "'")};"
  end

  # The email footer wordmark is a fixed-colour PNG, so unlike text it cannot follow the theme:
  # the dark asset disappears on a store whose background resolves to light text.
  def email_wordmark_image_path
    text_color_on_background == ContrastColor::WHITE ? "email/wordmark_logo_light.png" : "email/wordmark_logo.png"
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

  # The accent button's border: the accent itself unless the fill has vanished into the store's
  # background, the rule email_primary_button_style applies.
  def accent_edge_color
    ContrastColor.visible_indicator(accent_color_for_text_areas, background_color)
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

  def border_radius_css
    BORDER_RADIUS_CHOICES.fetch(border_radius)
  end

  def button_hover_offset_css
    BUTTON_HOVER_OFFSETS.fetch(button_hover)
  end

  def border_alpha_css
    BORDER_ALPHAS.fetch(text_color_on_background)
  end

  # A field's border is its only edge, and on a mid-tone background the stock alpha falls short
  # of 3:1, so each store gets the lowest alpha that reaches it.
  def control_border_alpha_css
    floor = CONTROL_BORDER_ALPHA_FLOORS.fetch(text_color_on_background)
    format("%.2f", ContrastColor.opacity_for_non_text_contrast(text_color_on_background, background_color, floor:))
  end

  # A white store sits on the stock page colour, so its cards and fields read as white surfaces on
  # a page, as in the app and the emails. Any other background is the page itself.
  # Mirrored by getStorePageBackground in color.ts.
  def page_background_color
    background_color.to_s.casecmp?(STOCK_BACKGROUND) ? STOCK_PAGE_BACKGROUND : background_color
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
    def normalize_colors
      self.background_color = HexColorValidator.normalize(background_color)
      self.highlight_color = HexColorValidator.normalize(highlight_color)
    end

    def custom_style_attributes_safe?
      HexColorValidator.safe_for_css?(highlight_color) &&
        HexColorValidator.safe_for_css?(background_color) &&
        font.in?(FONT_CHOICES) &&
        BORDER_RADIUS_CHOICES.key?(border_radius) &&
        BUTTON_HOVER_OFFSETS.key?(button_hover)
    end

    def clear_custom_style_cache
      Rails.cache.delete custom_style_cache_name
    end

    def share_image_is_valid
      # Signed ids of attached blobs reach other users (avatars, commission
      # files). Re-sending this profile's own blob reuses its attachment, so
      # this only runs for a blob new to the profile.
      if share_image.blob.attachments.exists?
        errors.add(:base, "That image is already used elsewhere. Please upload a new share image.")
        return
      end

      if share_image.byte_size > MAXIMUM_SHARE_IMAGE_FILE_SIZE
        errors.add(:base, "Please upload a share image smaller than #{ActiveSupport::NumberHelper.number_to_human_size(MAXIMUM_SHARE_IMAGE_FILE_SIZE)}.")
        return
      end

      unless ALLOWED_SHARE_IMAGE_CONTENT_TYPES.include?(share_image.content_type.to_s.downcase)
        errors.add(:base, "Please upload a share image in JPG or PNG format.")
      end
    end
end
