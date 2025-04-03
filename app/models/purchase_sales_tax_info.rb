# frozen_string_literal: true

class PurchaseSalesTaxInfo < ApplicationRecord
  belongs_to :purchase, optional: true
end
