# DRY RUN (read-only): assemble the staged payload, sanitize, report SHAs. No save.
require "base64"
MARKER = 'data-mz1a0b76b="1"'
KEY = "mz1a0b76"
u = User.find_by(email: "teonfox8@gmail.com")
raise "user mismatch" unless u && u.id == 28666433 && u.username == "maezart" && !u.suspended?
l = u.links.find_by(custom_permalink: "the-girl-who-carried-a-little-light")
raise "link mismatch" unless l && l.id == 14324814
pg = Page.find_by(pageable_type: "Link", pageable_id: l.id)
raise "no page" unless pg
pre = pg.custom_html.to_s
puts "PRE_LEN=#{pre.length} PRE_SHA=#{Digest::SHA256.hexdigest(pre)[0,16]}"

parts = (0..8).map { |i| $redis.get("#{KEY}_#{i}") }
raise "redis chunk missing #{parts.each_index.select { |i| parts[i].nil? }.inspect}" if parts.any?(&:nil?)
b64 = parts.join
puts "B64_LEN=#{b64.length} B64_SHA=#{Digest::SHA256.hexdigest(b64)[0,16]}"
raw = Base64.strict_decode64(b64).force_encoding(Encoding::UTF_8)
raise "bad utf8" unless raw.valid_encoding?
raise "marker already present" if raw.include?(MARKER)
raise "style anchor not unique" unless raw.scan("<style>").size == 1
raw = raw.sub("<style>", "<style #{MARKER}>")
puts "RAW_LEN=#{raw.length} RAW_SHA=#{Digest::SHA256.hexdigest(raw)[0,16]}"

res = Ai::PageSanitizer.sanitize_with_report(raw)
out = res.html
puts "total_removed=#{res.report[:total_removed]} removed_tags=#{res.report[:removed_tags].map { |t| t[:tag] }.inspect}"
puts "idempotent=#{Ai::PageSanitizer.sanitize_with_report(out).html == out}"
puts "POST_LEN=#{out.length} POST_SHA=#{Digest::SHA256.hexdigest(out)[0,16]}"
puts "buys=#{out.scan('data-gumroad-action="buy"').size} imgs=#{out.scan('<img').size} datauris=#{out.scan('data:image').size} hosted=#{out.scan('public-files.gumroad.com').size} marker=#{out.include?(MARKER)}"
puts "under_cap=#{out.length <= Page::MAX_CUSTOM_HTML_LENGTH}"
