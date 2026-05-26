# frozen_string_literal: true

# Stores the public half of an Apple App Attest key generated in the Secure
# Enclave on a Gumroad Walks iOS install. We register the key once via
# `WalksAppAttestVerifier.attest`; every subsequent walks API call carries an
# assertion that we verify against this stored public key. The `counter`
# column is the StoreKit-style monotonic counter that prevents assertion
# replay — `advance_counter!` performs the CAS atomically.
class WalksAppAttestKey < ApplicationRecord
  ENVIRONMENTS = %w[production development].freeze

  has_one :walks_free_trial, dependent: :destroy

  validates :key_id, presence: true, uniqueness: true, length: { maximum: 64 }
  validates :public_key, presence: true
  validates :counter, numericality: { greater_than_or_equal_to: 0 }
  validates :environment, inclusion: { in: ENVIRONMENTS }

  def public_key_ec
    @public_key_ec ||= OpenSSL::PKey::EC.new(public_key)
  end

  # Conditional UPDATE so two concurrent assertions can't both succeed at the
  # same counter value. Returns true iff we won the race and the counter is
  # now `new_counter`.
  def advance_counter!(new_counter)
    n = self.class.where(id: id).where("counter < ?", new_counter)
      .update_all(counter: new_counter, last_used_at: Time.current, updated_at: Time.current)
    if n == 1
      self.counter = new_counter
      true
    else
      false
    end
  end

  def free_trial_consumed?
    walks_free_trial.present?
  end
end
