# frozen_string_literal: true

# The reviewed preview an execution must present: which accounts were eligible and the exact
# probation comment, transition version and prior state each was judged on.
class LowBalanceProbationRecovery::Snapshot
  PURPOSE = "low_balance_probation_recovery_snapshot"
  FORMAT = 1
  TTL = 1.hour

  class Invalid < StandardError; end

  attr_reader :accounts, :actor_id, :request_id

  def self.issue(evaluations, actor:, request_id:)
    expires_at = TTL.from_now
    payload = {
      "format" => FORMAT,
      "rules_digest" => LowBalanceProbationRecovery::RULES_DIGEST,
      "actor_id" => actor.id,
      "request_id" => request_id,
      "accounts" => evaluations.map(&:snapshot_facts),
    }
    [verifier.generate(payload, purpose: PURPOSE, expires_at:), expires_at]
  end

  # Only the admin who reviewed the preview may execute it, so a snapshot cannot be handed on.
  def self.verify!(token, actor:)
    raise Invalid, "snapshot is required" if token.blank?

    payload = verifier.verified(token.to_s, purpose: PURPOSE)
    raise Invalid, "snapshot is invalid or expired" unless payload.is_a?(Hash)
    raise Invalid, "snapshot format is not supported" unless payload["format"] == FORMAT
    raise Invalid, "snapshot was reviewed under different recovery rules" unless payload["rules_digest"] == LowBalanceProbationRecovery::RULES_DIGEST
    raise Invalid, "snapshot was reviewed by a different admin" unless payload["actor_id"] == actor.id

    new(payload)
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    raise Invalid, "snapshot is invalid or expired"
  end

  def self.verifier = Rails.application.message_verifier(PURPOSE)
  private_class_method :verifier

  def initialize(payload)
    @accounts = Array(payload["accounts"]).index_by { _1["user_external_id"] }
    @actor_id = payload["actor_id"]
    @request_id = payload["request_id"]
  end
end
