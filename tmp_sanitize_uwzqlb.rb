#!/usr/bin/env ruby
require "active_support/all"
require "loofah"
module Ai; end
load "app/services/ai/page_sanitizer.rb"
raw = File.read("/tmp/att_1a1049fe2b0a4e10/payload.html")
puts "input_bytes=#{raw.bytesize} input_chars=#{raw.length}"
r = Ai::PageSanitizer.sanitize_with_report(raw)
html = r.html; rep = r.report
puts "out_bytes=#{html.bytesize} out_chars=#{html.length}"
puts "total_removed=#{rep[:total_removed]}"
puts "removed_tags=#{rep[:removed_tags].inspect}"
puts "removed_attributes=#{rep[:removed_attributes].inspect}"
puts "IDENTICAL=#{html == raw}"
puts "idempotent=#{Ai::PageSanitizer.sanitize(html) == html}"
puts "marker=#{html.include?('data-hs-uwzqlb')}"
puts "buy=#{html.scan('data-gumroad-action=\"buy\"').size}"
puts "hero_hosted=#{html.scan('6j4ergc85bc92k0cwnu1d1i48fqm').size}"
puts "webp=#{html.scan('data:image/webp;base64,').size}"
puts "jpeg_left=#{html.scan('data:image/jpeg').size}"
if html != raw
  i = (0...[raw.length, html.length].min).find { |k| raw[k] != html[k] } || [raw.length, html.length].min
  puts "FIRST_DIFF_AT=#{i}"
  puts "RAW=#{raw[[i-120,0].max, 240].inspect}"
  puts "OUT=#{html[[i-120,0].max, 240].inspect}"
end
File.write("/tmp/att_1a1049fe2b0a4e10/payload_sanitized.html", html)
