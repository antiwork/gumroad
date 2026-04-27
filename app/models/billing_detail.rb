# frozen_string_literal: true

class BillingDetail < ApplicationRecord
  belongs_to :purchaser, class_name: "User"

  validates :full_name, :street_address, :city, :zip_code, :country_code, presence: true
  validates :state, presence: true, if: :us_address?
  validates :country_code, length: { is: 2 }
  validates :purchaser_id, uniqueness: true

  def us_address?
    country_code == "US"
  end

  def to_invoice_address_fields
    {
      full_name:,
      street_address:,
      city:,
      state: state.presence,
      zip_code:,
      country_code:,
    }
  end
end
