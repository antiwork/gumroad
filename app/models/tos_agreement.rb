# frozen_string_literal: true

class TosAgreement < ApplicationRecord
  include ExternalId

  belongs_to :user, optional: true

  validates :user, presence: true
end
