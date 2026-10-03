require "digest"
u = User.find_by(email: "wyloramusic@gmail.com")
raise "no user" unless u
pg = u.page
raise "no page" unless pg
h = pg.custom_html.to_s

NEEDLE = "\n<style data-wyl1a0fc163=\"1\">"
raise "needle x#{h.scan(NEEDLE).size}" unless h.scan(NEEDLE).size == 1
raise "opens #{h.scan('<style').size} closes #{h.scan('</style>').size}" unless h.scan('</style>').size == h.scan('<style').size - 1
out = h.sub(NEEDLE) { "\n</style>\n\n<style data-wyl1a0fc163=\"1\">" }
raise "still unbalanced" unless out.scan('<style').size == out.scan('</style>').size
raise "open count moved" unless out.scan('<style').size == h.scan('<style').size
raise "main lost" unless out.scan('</main>').size == 1
raise "tail" unless out.end_with?("</style>\n\n</main>")
raise "marker" unless out.include?("data-wyl1a0fc163")
r = Ai::PageSanitizer.sanitize_with_report(out)
puts "PRE2=#{Digest::SHA256.hexdigest(h)} LEN2=#{h.length}"
puts "POST2=#{Digest::SHA256.hexdigest(out)} LEN3=#{out.length} DELTA=#{out.length - h.length}"
puts "SAN_EQ=#{r.html == out} REMOVED=#{r.report[:total_removed]}"
puts "STYLE_#{out.scan('<style').size}_CLOSE_#{out.scan('</style>').size}"
puts "TAIL=#{out[-120..].inspect}"
puts "DONE"
