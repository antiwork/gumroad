# frozen_string_literal: true

# Deliberately not paper-trailed: a live credential must not land in `versions`, which outlives GDPR
# erasure.
class PingSigningSetting < ApplicationRecord
  SECRET_BYTES = 32

  belongs_to :user

  validates :secret, presence: true
end
