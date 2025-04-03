# frozen_string_literal: true

class ZipTaxRate < ApplicationRecord
  include FlagShihTzu
  include Deletable
  include JsonData

  has_flags 1 => :is_seller_responsible,
            2 => :is_epublication_rate,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  attr_json_data_accessor :invoice_sales_tax_id
  attr_json_data_accessor :applicable_years

  has_many :purchases

  validates :combined_rate, presence: true
  validates :country, length: { is: 2 }

  alias opt_out_eligible is_seller_responsible
end
