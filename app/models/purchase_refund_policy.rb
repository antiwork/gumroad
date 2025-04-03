# frozen_string_literal: true

class PurchaseRefundPolicy < ApplicationRecord
  belongs_to :purchase, optional: true

  stripped_fields :title, :fine_print

  validates :purchase, presence: true, uniqueness: true
  validates :title, presence: true
end
