# frozen_string_literal: true

class PurchasingPowerParityInfo < ApplicationRecord
  belongs_to :purchase

  validates :purchase, presence: true, uniqueness: true

  def factor
    super / 100.0
  end

  def factor=(new_factor)
    super(new_factor * 100)
  end
end
