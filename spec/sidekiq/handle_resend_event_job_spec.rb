# frozen_string_literal: true

require "spec_helper"

RSpec.describe HandleResendEventJob do
  describe "queue routing" do
    it "runs on the resend_webhooks queue, not :low, so callback volume does not size the Sidekiq fleet" do
      # The Sidekiq autoscaler reads the `low` queue depth to size the fleet. Resend
      # delivery callbacks arrive as bursts, so routing this job anywhere but its own
      # queue lets a callback wave spike the fleet and the master's gp3 read IOPS.
      expect(described_class.sidekiq_options["queue"]).to eq(:resend_webhooks)
    end
  end
end