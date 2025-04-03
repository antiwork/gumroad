# frozen_string_literal: true

class PurchaseCustomField < ApplicationRecord
  include FlagShihTzu

  has_flags 1 => :is_post_purchase,
            flag_query_mode: :bit_operator,
            check_for_column: false

  def self.build_from_custom_field(custom_field:, value:, bundle_product: nil)
    build(custom_field:, value:, bundle_product:, name: custom_field.name, field_type: custom_field.type, custom_field_id: custom_field.id, is_post_purchase: custom_field.is_post_purchase?)
  end

  belongs_to :purchase
  # Normally this is a temporary association, only used until the custom fields are moved to the
  # product purchases by Purchase::CreateBundleProductPurchaseService. However, if the purchase is
  # created but later fails (e.g. SCA abandoned) the custom fields will stay linked to the bundle purchase.
  belongs_to :bundle_product, optional: true

  alias_attribute :type, :field_type

  normalizes :value, with: -> { _1&.strip&.squeeze(" ").presence }

  before_validation :normalize_boolean_value, if: -> { CustomField::BOOLEAN_TYPES.include?(field_type) }

  validates :field_type, inclusion: { in: CustomField::TYPES }
  validates :name, presence: true

  validate :value_valid_for_custom_field, if: :custom_field

  has_many_attached :files

  belongs_to :custom_field, optional: true

  def value
    # The `value` column is a string; for it to match the field_type we need to cast it.
    CustomField::BOOLEAN_TYPES.include?(field_type) ? ActiveModel::Type::Boolean.new.cast(read_attribute(:value)) : read_attribute(:value).to_s
  end

  private
    def normalize_boolean_value
      self.value = !!value
    end

    def value_valid_for_custom_field
      case custom_field.type
      when CustomField::TYPE_TEXT, CustomField::TYPE_LONG_TEXT
        errors.add(:value, :blank) if custom_field.required? && value.blank?
      when CustomField::TYPE_TERMS
        errors.add(:value, :blank) if value != true
      when CustomField::TYPE_CHECKBOX
        errors.add(:value, :blank) if custom_field.required? && value != true
      when CustomField::TYPE_FILE
        errors.add(:value, :blank) if custom_field.required? && files.none?
        errors.add(:value, "cannot be set for file custom field") if value.present?
      end
    end
end
