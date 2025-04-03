# frozen_string_literal: true

class PurchaseWalletType < ApplicationRecord
  belongs_to :purchase, optional: true
end
