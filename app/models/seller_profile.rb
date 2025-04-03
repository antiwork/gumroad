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

  def custom_styles
    Rails.cache.fetch(custom_style_cache_name) do
      component_path = File.read(Rails.root.join("app", "views", "layouts", "custom_styles", "styles.scss.erb"))
      sass = ERB.new(component_path).result(binding)

      SassC::Engine.new(
        sass,
        syntax: :scss,
        load_paths: Rails.application.config.assets.paths,
        read_cache: false,
        cache: false,
        style: :compressed,
        ).render
    end
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
    "users/#{seller.id}/custom_styles_v2"
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
