# frozen_string_literal: true

# Marker row: this attested key has used its one free walk. The unique index
# on `walks_app_attest_key_id` is what makes `consume` race-safe — two parallel
# realtime_tokens requests against the same key produce exactly one row.
class WalksFreeTrial < ApplicationRecord
  belongs_to :walks_app_attest_key

  validates :walks_app_attest_key_id, uniqueness: true
  validates :consumed_at, presence: true

  def self.consume(walks_app_attest_key:)
    create!(walks_app_attest_key:, consumed_at: Time.current)
    true
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    false
  end
end
