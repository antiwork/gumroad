# frozen_string_literal: true

class UserTaxForm < ApplicationRecord
  include JsonData

  TAX_FORM_TYPES = ["us_1099_k", "us_1099_misc"].freeze
  MIN_TAX_YEAR = 2020

  belongs_to :user

  attr_json_data_accessor :stripe_account_id

  validates :tax_year, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: MIN_TAX_YEAR }
  validates :tax_form_type, presence: true, inclusion: { in: TAX_FORM_TYPES }
  validates :user_id, uniqueness: { scope: [:tax_year, :tax_form_type] }

  scope :for_year, ->(year) { where(tax_year: year) }
end
