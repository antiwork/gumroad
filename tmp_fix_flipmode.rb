require "digest"
OLD = %q{<p>Whatever you decide. Checkout is set as pay what you want with a $0 minimum, so you can start for nothing and pay what it turns out to be worth to you.</p>}
NEW = %q{<p>It is set up as pay what you want, so you decide what it is worth to you. The page shows the suggested amount, and you are free to pay less, including nothing.</p>}
PRE_PIN = "7ec8726969fa28aa"
PRE_LEN = 10541
u = User.find_by(email: "garveyindustry5@gmail.com")
raise "USER" unless u && u.external_id == "5129068866782" && u.username == "garveycraft5"
raise "SUSPENDED" if u.suspended?
l = Link.where(unique_permalink: "qkicyh").first
raise "LINK" unless l && l.id == 15024361
pre = l.custom_html.to_s
raise "PRE_LEN_MISMATCH #{pre.length} vs #{PRE_LEN}" unless pre.length == PRE_LEN
raise "PRE_SHA" unless Digest::SHA256.hexdigest(pre)[0,16] == PRE_PIN
raise "OLD_OCC #{pre.scan(OLD).size}" unless pre.scan(OLD).size == 1
raise "NEW_PRESENT" if pre.include?(NEW)
post = pre.sub(OLD) { NEW }
raise "DELTA" unless pre.length - post.length == OLD.length - NEW.length
raise "TOO_BIG" if post.length > Page::MAX_CUSTOM_HTML_LENGTH
raise "SAN_NOT_IDEMPOTENT" unless Ai::PageSanitizer.sanitize(post) == post
puts "EXPECT_LEN=#{post.length} EXPECT_SHA16=#{Digest::SHA256.hexdigest(post)[0,16]}"
res = Pages::CustomHtmlWriter.edit!(l, find: OLD, replace: NEW)
pg = Page.where(pageable_type: "Link", pageable_id: l.id).order(:id).last
stored = pg.reload.custom_html.to_s
raise "STORED_MISMATCH #{stored.length}" unless stored.length == post.length && Digest::SHA256.hexdigest(stored) == Digest::SHA256.hexdigest(post)
raise "OLD_SURVIVES" if stored.include?(OLD)
raise "MARKER" unless stored.include?("flipmode-v1")
puts "EDITED page_id=#{pg.id} len=#{stored.length} POST_SHA16=#{Digest::SHA256.hexdigest(stored)[0,16]} BUY=#{stored.scan(%q{data-gumroad-action="buy"}).size} NEW=#{stored.scan(NEW).size}"
