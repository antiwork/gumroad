# frozen_string_literal: true

class ProcessorPaymentIntent < ApplicationRecord
  belongs_to :purchase

  validates_uniqueness_of :purchase
  validates_presence_of :intent_id
end
