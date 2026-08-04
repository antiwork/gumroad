# frozen_string_literal: true

require "test_helper"

class RobotsServicePolicyTest < ActiveSupport::TestCase
  AI_CRAWLERS = %w[GPTBot ClaudeBot Claude-Web PerplexityBot Google-Extended CCBot]

  test "robots rules do not disallow AI crawlers" do
    rules = RobotsService.new.user_agent_rules

    AI_CRAWLERS.each do |bot|
      assert rules.grep(/#{Regexp.escape(bot)}/i).empty?,
             "robots.txt must not carry a rule group for #{bot}; AI crawlers are intentionally allowed"
    end
  end

  test "robots rules only restrict private purchase pages under the wildcard group" do
    assert_equal ["User-agent: *", "Disallow: /purchases/"], RobotsService.new.user_agent_rules
  end
end
