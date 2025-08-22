# frozen_string_literal: true

class DiscountCollection < ApplicationRecord
  include ExternalId
  include Deletable

  belongs_to :user
  has_many :offer_codes, dependent: :nullify

  validates :name, presence: true
  validates :user, presence: true

  scope :alive, -> { where(deleted_at: nil) }
end
