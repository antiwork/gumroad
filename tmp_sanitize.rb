#!/usr/bin/env ruby
# Local sanitizer pre-flight for the seller-supplied landing page
require "active_support/all"
require "loofah"
module Ai; end
load "app/services/ai/page_sanitizer.rb"

raw = File.read("/tmp/landing_115fe.html")
puts "input_bytes=#{raw.bytesize} input_chars=#{raw.length}"

begin
  result = Ai::PageSanitizer.sanitize_with_report(raw)
  html = result.html
  rep = result.report
  puts "sanitized_bytes=#{html.bytesize}"
  puts "total_removed=#{rep[:total_removed]}"
  puts "removed_tags=#{rep[:removed_tags].inspect}"
  puts "removed_attributes=#{rep[:removed_attributes].inspect}"
  # idempotence: sanitize the sanitized output, must be byte-identical
  again = Ai::PageSanitizer.sanitize_with_report(html)
  puts "idempotent=#{again.html == html}"
  # buy affordance still present after sanitize
  puts "buy_postMessage=#{html.include?('gumroad:checkout')}"
  puts "action_buy_count=#{html.scan('data-gumroad-action="buy"').size}"
  # drop to a working file for staging
  File.write("/tmp/landing_115fe_sanitized.html", html)
rescue => e
  puts "ERROR #{e.class}: #{e.message}"
  puts e.backtrace.first(5)
end