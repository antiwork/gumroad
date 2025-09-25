# frozen_string_literal: true

class BasePrice < ApplicationRecord
  has_paper_trail

  self.table_name = "prices"

  include BasePrice::Recurrence
  include BasePrice::FixedDuration
  include ExternalId
  include ProductsHelper
  include Deletable
  include FlagShihTzu

  validates :price_cents, :currency, presence: true
  validates :fixed_duration_months,
    numericality: { greater_than: 0, only_integer: true }, allow_nil: true
  validate :fixed_duration_must_be_multiple_of_recurrence_period

  has_flags 1 => :is_rental,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  scope :is_buy, -> { self.not_is_rental }

  def is_buy?
    !is_rental?
  end

  def is_default_recurrence?
    recurrence == link.subscription_duration.to_s
  end


  private
end
