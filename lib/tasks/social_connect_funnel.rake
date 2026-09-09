# frozen_string_literal: true

namespace :social_connect do
  desc "Print the social-connect funnel report. Usage: rake social_connect:funnel_report[2026-09-01]"
  task :funnel_report, [:since] => :environment do |_task, args|
    since = if args[:since].present?
      parsed = begin
        Time.zone.parse(args[:since])
      rescue ArgumentError, TypeError
        nil
      end
      if parsed.nil?
        abort "Invalid since date #{args[:since].inspect}. Use YYYY-MM-DD or an ISO-8601 timestamp."
      end
      parsed
    else
      2.weeks.ago
    end
    puts SocialConnectFunnelReport.new(since:).to_text
  end
end
