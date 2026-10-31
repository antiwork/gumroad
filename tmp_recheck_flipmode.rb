u = User.find_by(email: "garveyindustry5@gmail.com")
l = Link.where(unique_permalink: "qkicyh").first
puts "LINK custom_html len=#{l.custom_html.to_s.length} sha16=#{Digest::SHA256.hexdigest(l.custom_html.to_s)[0,16]}"
pgs = Page.where(pageable_type: "Link", pageable_id: l.id).order(:id)
puts "PAGES #{pgs.pluck(:id, :slug).inspect}"
pg = pgs.last
if pg
  s = pg.custom_html.to_s
  puts "PAGE #{pg.id} len=#{s.length} sha16=#{Digest::SHA256.hexdigest(s)[0,16]}"
  puts "MARKER=#{s.include?('flipmode-v1')} BUY=#{s.scan(%q{data-gumroad-action="buy"}).size} PRICE=#{s.scan(%q{data-gumroad-field="price"}).size} IMG=#{s.scan('<img').size}"
end
