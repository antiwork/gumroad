# frozen_string_literal: true

class OrderPurchase < ApplicationRecord
  belongs_to :order
  belongs_to :purchase

  validates_presence_of :order
  validates_presence_of :purchase
end
