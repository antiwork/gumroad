# frozen_string_literal: true

require "test_helper"

class RobotsServicePolicyTest < ActiveSupport::TestCase
  AI_CRAWLERS = %w[GPTBot ClaudeBot Claude-Web PerplexityBot Google-Extended CCBot]

  test "robots rules do not disallow AI crawlers on any host" do
    [false, true].each do |storefront_host|
      rules = RobotsService.new(storefront_host:).user_agent_rules

      AI_CRAWLERS.each do |bot|
        assert rules.grep(/#{Regexp.escape(bot)}/i).empty?,
               "robots.txt must not carry a rule group for #{bot}; AI crawlers are intentionally allowed"
      end
    end
  end

  test "robots rules only restrict private purchase pages under the wildcard group" do
    assert_equal ["User-agent: *", "Disallow: /purchases/"], RobotsService.new.user_agent_rules
  end

  test "storefront robots rules add a bingbot crawl delay and nothing else" do
    assert_equal [
      "User-agent: bingbot",
      "Crawl-delay: #{RobotsService::STOREFRONT_BINGBOT_CRAWL_DELAY_SECONDS}",
      "Disallow: /purchases/",
      "",
      "User-agent: *",
      "Disallow: /purchases/"
    ], RobotsService.new(storefront_host: true).user_agent_rules
  end

  test "bingbot crawl delay stays within the 1-30 second range Bing accepts" do
    assert_includes 1..30, RobotsService::STOREFRONT_BINGBOT_CRAWL_DELAY_SECONDS
  end
end
