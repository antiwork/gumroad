# frozen_string_literal: true

class Tip < ApplicationRecord
  belongs_to :purchase
  validates :value_cents, numericality: { greater_than: 0 }
end
