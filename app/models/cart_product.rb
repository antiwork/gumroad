# frozen_string_literal: true

class CartProduct < ApplicationRecord
  include ExternalId
  include Deletable

  URL_PARAMETERS_JSON_SCHEMA = { type: "object", additionalProperties: { type: "string" } }.freeze
  ACCEPTED_OFFER_DETAILS_JSON_SCHEMA = {
    type: "object",
    properties: {
      original_product_id: { type: ["string", "null"] },
      original_variant_id: { type: ["string", "null"] },
    },
    additionalProperties: false,
  }.freeze

  belongs_to :cart, touch: true
  belongs_to :product, class_name: "Link"
  belongs_to :option, class_name: "BaseVariant", optional: true
  belongs_to :affiliate, optional: true
  belongs_to :accepted_offer, class_name: "Upsell", optional: true

  after_initialize :assign_default_values

  validates :price, :quantity, :referrer, presence: true

  validate :ensure_url_parameters_conform_to_schema
  validate :ensure_accepted_offer_details_conform_to_schema

  private
    def assign_default_values
      self.url_parameters = {} if url_parameters.nil?
      self.accepted_offer_details = {} if accepted_offer_details.nil?
    end

    def ensure_url_parameters_conform_to_schema
      JSON::Validator.fully_validate(URL_PARAMETERS_JSON_SCHEMA, url_parameters).each { errors.add(:url_parameters, _1) }
    end

    def ensure_accepted_offer_details_conform_to_schema
      JSON::Validator.fully_validate(ACCEPTED_OFFER_DETAILS_JSON_SCHEMA, accepted_offer_details).each { errors.add(:accepted_offer_details, _1) }
    end
end
