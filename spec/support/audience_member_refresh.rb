# frozen_string_literal: true

# Audience projection rebuilds run out of band in production (RefreshAudienceMemberJob,
# see Purchase::AudienceMember). Most specs predate that and assert on audience_members
# rows right after saving a purchase, so by default the enqueue is executed inline here.
# Tag an example or group with `defer_audience_refresh: true` to keep the real queueing
# behavior and assert on the enqueue itself.
RSpec.configure do |config|
  config.before(:each) do |example|
    next if example.metadata[:defer_audience_refresh]

    allow(RefreshAudienceMemberJob).to receive(:perform_async) do |*args|
      RefreshAudienceMemberJob.new.perform(*args)
    end
  end
end
