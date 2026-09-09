# frozen_string_literal: true

namespace :social_connect do
  desc "Print the social-connect funnel report. Usage: rake social_connect:funnel_report[2026-09-01]"
  task :funnel_report, [:since] => :environment do |_task, args|
    since = args[:since].present? ? Time.zone.parse(args[:since]) : 2.weeks.ago
    puts SocialConnectFunnelReport.new(since:).to_text
  end
end
