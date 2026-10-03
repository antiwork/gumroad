require "digest"
PRE2  = "d9d282f9b8a27a326e7a49aba584c7b338d0c852b980c0ad2a23e2cbe041e2c0"
POST2 = "0dde003140216ac0ee57611cf1c0a247a9575d108eabb0d66adc98577c5d5664"

u = User.find_by(email: "wyloramusic@gmail.com")
raise "no user" unless u
raise "suspended" if u.suspended?
pg = u.page
raise "no page" unless pg

NEEDLE = "\n<style data-wyl1a0fc163=\"1\">"
pg.with_lock do
  cur = pg.custom_html.to_s
  raise "BASE_MOVED #{Digest::SHA256.hexdigest(cur)[0,16]}" unless Digest::SHA256.hexdigest(cur) == PRE2
  raise "needle x#{cur.scan(NEEDLE).size}" unless cur.scan(NEEDLE).size == 1
  raise "not broken #{cur.scan('<style').size}/#{cur.scan('</style>').size}" unless cur.scan('</style>').size == cur.scan('<style').size - 1
  out = cur.sub(NEEDLE) { "\n</style>\n\n<style data-wyl1a0fc163=\"1\">" }
  raise "POST2 mismatch" unless Digest::SHA256.hexdigest(out) == POST2
  raise "unbalanced after" unless out.scan('<style').size == out.scan('</style>').size
  r = Ai::PageSanitizer.sanitize_with_report(out)
  raise "sanitizer shifted #{r.report[:total_removed]}" unless r.html == out
  pg.custom_html = out
  pg.save!
end

pg.reload
wrote = Digest::SHA256.hexdigest(pg.custom_html.to_s)
puts "WROTE=#{wrote} MATCH=#{wrote == POST2} LEN=#{pg.custom_html.length} OPEN=#{pg.custom_html.scan('<style').size} CLOSE=#{pg.custom_html.scan('</style>').size} MARKER=#{pg.custom_html.include?('data-wyl1a0fc163')}"
puts "DONE"
