# frozen_string_literal: true

class CustomField < ApplicationRecord
  include ExternalId, FlagShihTzu

  has_flags 1 => :is_post_purchase,
            2 => :collect_per_product,
            column: "flags",
            flag_query_mode: :bit_operator,
            check_for_column: false

  belongs_to :seller, class_name: "User"
  has_many :purchase_custom_fields
  has_and_belongs_to_many :products, class_name: "Link", join_table: "custom_fields_products", association_foreign_key: "product_id"


  URI_REGEXP = /\A#{URI.regexp([%w[http https]])}\z/

  TYPES = %w(text checkbox terms long_text file).freeze
  TYPES.each do |type|
    self.const_set("TYPE_#{type.upcase}", type)
  end

  alias_attribute :type, :field_type
  validates :field_type, inclusion: { in: TYPES }
  validates_presence_of :name
  validate :terms_valid_uri
  validate :type_not_boolean_if_post_purchase

  scope :global, -> { where(global: true) }

  BOOLEAN_TYPES = [TYPE_TERMS, TYPE_CHECKBOX].freeze

  FIELD_TYPE_TO_NODE_TYPE_MAPPING = {
    TYPE_TEXT => RichContent::SHORT_ANSWER_NODE_TYPE,
    TYPE_LONG_TEXT => RichContent::LONG_ANSWER_NODE_TYPE,
    TYPE_FILE => RichContent::FILE_UPLOAD_NODE_TYPE,
  }.freeze

  FILE_FIELD_NAME = "File upload"

  before_validation :set_default_name

  def as_json(*)
    {
      id: external_id,
      type:,
      name:,
      required:,
      global:,
      collect_per_product:,
      products: products.map(&:external_id)
    }
  end

  private
    def terms_valid_uri
      if field_type == TYPE_TERMS && !URI_REGEXP.match?(name)
        errors.add(:base, "Please provide a valid URL for custom field of Terms type.")
      end
    end

    def set_default_name
      self.name = FILE_FIELD_NAME if type == TYPE_FILE && name.blank?
    end

    def type_not_boolean_if_post_purchase
      if is_post_purchase? && BOOLEAN_TYPES.include?(field_type)
        errors.add(:base, "Boolean post-purchase fields are not allowed")
      end
    end
end
