# frozen_string_literal: true

class RefundPaymentMethod < ApplicationRecord
  belongs_to :user
  belongs_to :credit_card

  validates :cardholder_name, presence: true
end
