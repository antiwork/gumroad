# frozen_string_literal: true

# Mirror spec/support/audience_member_refresh.rb. Production schedules
# RefreshAudienceMemberJob (see Purchase::AudienceMember); most Minitest
# examples predate that and assert on audience_members right after save.
# Minitest has no example metadata, so perform_async runs the rebuild inline here.
module RefreshAudienceMemberJobInline
  def perform_async(*args)
    new.perform(*args)
  end
end
RefreshAudienceMemberJob.singleton_class.prepend(RefreshAudienceMemberJobInline)
