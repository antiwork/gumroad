# frozen_string_literal: true

class StripeApplePayDomain < ApplicationRecord
  belongs_to :user, optional: true

  validates_presence_of :user, :domain, :stripe_id
end
