# frozen_string_literal: true

# Marker row: this attested key has used its one free walk. The unique index
# on `walks_app_attest_key_id` is what makes `consume` race-safe — two parallel
# realtime_tokens requests against the same key produce exactly one row.
#
# `synthesis_attempts` caps how many post-walk Anthropic synthesis calls each
# free walk gets. The intent of the feature is "one walk → one product draft,"
# but transient Anthropic failures need to be retryable, so we allow up to
# MAX_SYNTHESIS_ATTEMPTS calls per free walk. Without this cap the
# WalksFreeTrial row would act as a permanent "may call the Anthropic proxy"
# flag — letting a single device drive ~$1/call indefinitely against our key.
class WalksFreeTrial < ApplicationRecord
  MAX_SYNTHESIS_ATTEMPTS = 3

  belongs_to :walks_app_attest_key

  validates :walks_app_attest_key_id, uniqueness: true
  validates :consumed_at, presence: true
  validates :synthesis_attempts, numericality: { greater_than_or_equal_to: 0 }

  def self.consume(walks_app_attest_key:)
    create!(walks_app_attest_key:, consumed_at: Time.current)
    true
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    false
  end

  # Atomic increment guarded by a WHERE clause — two parallel synthesis
  # requests can't both succeed at the same attempt count, and a request
  # past the cap can't accidentally advance the counter. Returns true iff
  # we successfully claimed a slot.
  def consume_synthesis_attempt
    n = self.class
      .where(id: id)
      .where("synthesis_attempts < ?", MAX_SYNTHESIS_ATTEMPTS)
      .update_all([
        "synthesis_attempts = synthesis_attempts + 1, updated_at = ?",
        Time.current,
      ])
    if n == 1
      self.synthesis_attempts += 1
      true
    else
      false
    end
  end
end
