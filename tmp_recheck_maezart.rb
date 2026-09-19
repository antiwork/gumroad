u = User.find_by(email: "teonfox8@gmail.com")
l = u.links.find_by(custom_permalink: "the-girl-who-carried-a-little-light")
pg = Page.find_by(pageable_type: "Link", pageable_id: l.id)
h = pg.custom_html.to_s
puts "PAGE #{pg.id} updated=#{pg.updated_at.utc.iso8601} len=#{h.length} sha16=#{Digest::SHA256.hexdigest(h)[0,16]}"
puts "buys=#{h.scan('data-gumroad-action="buy"').size} imgs=#{h.scan('<img').size} datauris=#{h.scan('data:image').size} hosted=#{h.scan('public-files.gumroad.com').size} styles=#{h.scan('<style').size}"
puts "MARKERS=#{h.scan(/data-[a-z0-9]+="?[a-z0-9-]+/).uniq.select { |m| m.start_with?('data-mz', 'data-shw', 'data-mzl') }.inspect}"
puts "IMAGESMAP #{h[/var IMAGES = \{.{0,500}/m].to_s.inspect}"
puts "ALTS #{h.scan(/<img[^>]*alt="([^"]*)"/).flatten.map { |a| a[0,60] }.inspect}"
puts "COMMENTS:"
Comment.where(commentable_type: "User", commentable_id: u.id).order(:id).last(3).each do |c|
  puts "=== #{c.created_at.utc.iso8601} #{c.content.to_s[0,900]}"
end
