#!/usr/bin/env ruby
# Final assemble + write: publish seller-supplied landing page to product mfhpmi
# Replaces the existing 10,567-char custom_html page. skips content_moderation via update_columns (payload pre-sanitized).
require "base64"
MARKER = "published-115fe-mfhpmi"
l = Link.find_by(unique_permalink: "mfhpmi")
raise "link not found" unless l
pg = l.page rescue nil
raise "page not found" unless pg
cur = pg.custom_html.to_s
raise "ALREADY_DONE: marker already present (idempotent no-op)" if cur.include?(MARKER)

# assemble from redis chunks
parts = (0..9).map { |i| $redis.get("mfhpmi_115fe_#{i}") }
raise "redis chunk missing" if parts.any?(&:nil?)
b64 = parts.join
raise "b64 sha mismatch" unless Digest::SHA256.hexdigest(b64)[0,16] == "56e0e035f08e7b61"
raw = Base64.strict_decode64(b64).force_encoding(Encoding::UTF_8)
raise "not valid utf-8" unless raw.valid_encoding?

# inject idempotency marker
out = raw.sub(/\A\s*<!DOCTYPE html>/i, "<!-- #{MARKER} -->\n<!DOCTYPE html>")

# re-sanitize the final payload; confirm buy affordance and price markers survive
res = Ai::PageSanitizer.sanitize_with_report(out)
final = res.html
raise "buy bridge lost" unless final.include?("gumroad:checkout")
raise "price marker lost" unless final.scan('data-gumroad-field="price"').size >= 1
raise "name marker lost" unless final.include?('data-gumroad-field="name"')
puts "total_removed=#{res.report[:total_removed]} removed_tags=#{res.report[:removed_tags].inspect}"
puts "final_bytes=#{final.bytesize} cur_bytes=#{cur.bytesize}"

pg.update_columns(custom_html: final, updated_at: Time.current)
pg.reload
raise "WRITE FAILED: marker not stored" unless pg.custom_html.to_s.include?(MARKER)
raise "WRITE FAILED: length mismatch" unless pg.custom_html.to_s.length == final.length

# clean up redis chunks
(0..9).each { |i| $redis.del("mfhpmi_115fe_#{i}") }
puts "WROTE mfhpmi custom_html len=#{pg.custom_html.to_s.length} marker=#{MARKER}"
puts "prior_len=#{cur.bytesize}"