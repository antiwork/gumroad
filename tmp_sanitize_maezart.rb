module Ai; end
require "active_support/all"
require "loofah"
load File.expand_path("app/services/ai/page_sanitizer.rb", Dir.pwd)

payload = File.read("/tmp/maezart_payload.html", encoding: "UTF-8")
res = Ai::PageSanitizer.sanitize_with_report(payload)
out = res.html
puts "total_removed=#{res.report[:total_removed]}"
puts "removed_tags=#{res.report[:removed_tags].inspect}"
puts "removed_attrs=#{res.report[:removed_attributes].inspect}"
puts "idempotent=#{Ai::PageSanitizer.sanitize_with_report(out).html == out}"
puts "in_bytes=#{payload.bytesize} out_bytes=#{out.bytesize}"
puts "buys=#{out.scan('data-gumroad-action="buy"').size} imgs=#{out.scan('<img').size} datauris=#{out.scan('data:image').size} hosted=#{out.scan('public-files.gumroad.com').size}"
puts "first_diff_at=#{out == payload ? 'none' : (0...out.length).find { |i| out[i] != payload[i] }.inspect}"
puts "watchdog=#{out.include?('var IMAGES')} #{out.include?('Get the storybook')}"
File.write("/tmp/maezart_sanitized.html", out)
