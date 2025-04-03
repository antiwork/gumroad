# frozen_string_literal: true

class ChargePurchase < ApplicationRecord
  belongs_to :charge
  belongs_to :purchase
end
