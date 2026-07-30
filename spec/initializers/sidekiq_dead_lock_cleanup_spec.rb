# frozen_string_literal: true

require "spec_helper"

# The death handler is what releases an `until_executed` lock when a job dies. It read the pre-v7
# `unique_digest` key and called a class method that no longer exists, so on sidekiq-unique-jobs v8
# it silently released nothing: the lock outlived the job and every later enqueue was dropped as a
# duplicate (gumroad-private#1576).
#
# These examples drive `SidekiqDeadLockCleanup::HANDLER` itself — the object the initializer
# registers — so the shipped code cannot drift away from what is tested here.
describe SidekiqDeadLockCleanup do
  let(:digests) { SidekiqUniqueJobs::Digests.new }

  it "releases a lock recorded under the v8 lock_digest key" do
    digest = "uniquejobs:spec-#{SecureRandom.hex(6)}"
    digests.add(digest)
    expect(digests.entries.keys).to include(digest)

    described_class::HANDLER.call({ SidekiqUniqueJobs::LOCK_DIGEST => digest }, StandardError.new)

    expect(digests.entries.keys).not_to include(digest)
  end

  it "does nothing when the job carries no digest" do
    expect { described_class::HANDLER.call({}, StandardError.new) }.not_to raise_error
  end

  # Guards the key name specifically: reading anything other than `lock_digest` is what made this
  # handler inert, and that failure is invisible at runtime.
  it "reads the digest from the key the installed gem writes" do
    digest = "uniquejobs:spec-key-#{SecureRandom.hex(6)}"
    digests.add(digest)

    described_class::HANDLER.call({ "unique_digest" => digest }, StandardError.new)

    expect(digests.entries.keys).to include(digest)
  end
end

describe ScheduleAbandonedCartEmailsJob do
  # A SIGKILL (OOM, deploy reap) fires no death event at all, so the TTL is the only backstop.
  # It must stay strictly under the 24h schedule interval: the lock's expiry is anchored at
  # enqueue and never refreshed, so a TTL equal to the period leaves the next day's enqueue
  # racing the expiry and possibly dropped too.
  it "bounds its until_executed lock with a TTL shorter than the daily schedule" do
    opts = described_class.sidekiq_options

    expect(opts["lock"].to_sym).to eq(:until_executed)
    expect(opts["lock_ttl"]).to eq(20.hours.to_i)
    expect(opts["lock_ttl"]).to be < 1.day.to_i
  end
end
