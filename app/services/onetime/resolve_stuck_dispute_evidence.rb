# frozen_string_literal: true

module Onetime
  class ResolveStuckDisputeEvidence
    TERMINAL_STATES = %w[won lost closed].freeze
    DEFAULT_ERROR_MESSAGE = "Dispute reached terminal state before evidence was submitted."

    def self.process
      new.process
    end

    def process
      scope = DisputeEvidence.not_resolved.joins(:dispute).where(disputes: { state: TERMINAL_STATES })

      scope.includes(:dispute).find_each do |evidence|
        ReplicaLagWatcher.watch
        evidence.update_as_resolved!(
          resolution: DisputeEvidence::RESOLUTION_REJECTED,
          error_message: "#{DEFAULT_ERROR_MESSAGE} (state=#{evidence.dispute.state})"
        )
        puts "Resolved DisputeEvidence #{evidence.id} (dispute #{evidence.dispute_id}, state=#{evidence.dispute.state})"
      end
    end
  end
end
