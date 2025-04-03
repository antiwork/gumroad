# frozen_string_literal: true

class BacktaxAgreement < ApplicationRecord
  include FlagShihTzu

  belongs_to :user
  has_one :credit
  has_many :backtax_collections

  has_flags 1 => :collected,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  module Jurisdictions
    AUSTRALIA = "AUSTRALIA"

    ALL = [AUSTRALIA].freeze
  end

  validates :jurisdiction, inclusion: { in: Jurisdictions::ALL }
  validates_presence_of :signature
end
