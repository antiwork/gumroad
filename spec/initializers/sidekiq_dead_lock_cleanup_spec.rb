# frozen_string_literal: true

require "spec_helper"

# The configured death handler is what releases an `until_executed` lock when a job dies. It
# read the pre-v7 `unique_digest` key and called a class method that no longer exists, so on
# sidekiq-unique-jobs v8 it silently released nothing: the lock outlived the job and every
# later enqueue was dropped as a duplicate (gumroad-private#1576).
describe "Sidekiq dead-lock cleanup", :sidekiq_inline do
  let(:handler) do
    lambda do |job, _ex|
      digest = job[SidekiqUniqueJobs::LOCK_DIGEST] || job["unique_digest"]
      SidekiqUniqueJobs::Digests.new.delete_by_digest(digest) if digest
    end
  end

  it "releases a lock recorded under the v8 lock_digest key" do
    digests = SidekiqUniqueJobs::Digests.new
    digest = "uniquejobs:spec-#{SecureRandom.hex(6)}"
    digests.add(digest)
    expect(digests.entries.keys).to include(digest)

    handler.call({ SidekiqUniqueJobs::LOCK_DIGEST => digest }, StandardError.new)

    expect(digests.entries.keys).not_to include(digest)
  end

  it "still releases a lock recorded under the legacy unique_digest key" do
    digests = SidekiqUniqueJobs::Digests.new
    digest = "uniquejobs:spec-legacy-#{SecureRandom.hex(6)}"
    digests.add(digest)

    handler.call({ "unique_digest" => digest }, StandardError.new)

    expect(digests.entries.keys).not_to include(digest)
  end

  it "does nothing when the job carries no digest" do
    expect { handler.call({}, StandardError.new) }.not_to raise_error
  end

  describe ScheduleAbandonedCartEmailsJob do
    # Without a TTL a SIGKILLed process (no death handler runs) strands the lock forever.
    it "bounds its until_executed lock with a TTL" do
      opts = described_class.sidekiq_options
      expect(opts["lock"].to_sym).to eq(:until_executed)
      expect(opts["lock_ttl"]).to eq(1.day.to_i)
    end
  end
end
