# frozen_string_literal: true

# The secret a seller's Ping endpoint verifies our signatures with, one row per opted-in seller.
#
# It lives in its own table rather than a `users` column because CONTRIBUTING forbids schema changes
# on `users` (too large; migrations there block deployments), and it is deliberately not
# paper-trailed: a live credential must not land in `versions.object_changes`, which survives GDPR
# erasure for weeks.
class PingSigningSetting < ApplicationRecord
  # Length of the generated secret, in bytes (`hex` emits two characters per byte).
  SECRET_BYTES = 32

  belongs_to :user

  validates :secret, presence: true
end
