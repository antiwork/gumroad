# frozen_string_literal: true

module Purchase::CustomFields
  extend ActiveSupport::Concern

  included do
    has_many :purchase_custom_fields, dependent: :destroy
  end

  def custom_fields
    purchase_custom_fields.map do |field|
      { name: field.name, value: field.value, type: field.type }
    end
  end
end
