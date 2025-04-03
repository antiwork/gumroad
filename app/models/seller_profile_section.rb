# frozen_string_literal: true

class SellerProfileSection < ApplicationRecord
  include ExternalId, FlagShihTzu

  belongs_to :seller, class_name: "User"
  belongs_to :product, class_name: "Link", optional: true
  validate :validate_json_data
  attribute :json_data, default: {}
  scope :on_profile, -> { where(product_id: nil) }

  has_flags 1 => :DEPRECATED_add_new_products,
            2 => :hide_header,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  private
    def self.inherited(subclass)
      subclass.define_singleton_method :json_schema do
        @__json_schema ||= JSON.parse(File.read(Rails.root.join("lib", "json_schemas", "#{subclass.name.underscore}.json").to_s))
      end

      subclass.json_schema["properties"].keys.each do |key|
        subclass.define_method key do
          json_data[key]
        end

        subclass.define_method :"#{key}=" do |value|
          json_data[key] = value
        end
      end

      super
    end

    def validate_json_data
      # slice away the "in schema [id]" part that JSON::Validator otherwise includes
      json_validator.validate(json_data).each { errors.add(:base, _1[..-48]) }
    end

    def json_validator
      @__json_validator ||= JSON::Validator.new(self.class.json_schema, insert_defaults: true, record_errors: true)
    end
end
