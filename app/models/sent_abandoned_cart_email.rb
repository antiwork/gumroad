# frozen_string_literal: true

class SentAbandonedCartEmail < ApplicationRecord
  belongs_to :cart
  belongs_to :installment
end
