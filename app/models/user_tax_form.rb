# frozen_string_literal: true

class UserTaxForm < ApplicationRecord
  TAX_FORM_TYPES = ["us_1099_k", "us_1099_misc"].freeze

  belongs_to :user

  validates :tax_year, presence: true, numericality: { only_integer: true, greater_than: 1900 }
  validates :tax_form_type, presence: true, inclusion: { in: TAX_FORM_TYPES }
  validates :user_id, uniqueness: { scope: [:tax_year, :tax_form_type] }

  scope :for_year, ->(year) { where(tax_year: year) }
end
