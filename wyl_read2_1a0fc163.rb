require "digest"
u = User.find_by(email: "wyloramusic@gmail.com")
raise "no user" unless u
puts "U id=#{u.id} email=#{u.email} suspended=#{u.suspended?} username=#{u.username.inspect}"
pg = u.page
raise "no root page" unless pg
h = pg.custom_html.to_s
puts "PG id=#{pg.id} slug=#{pg.slug.inspect} pageable=#{pg.pageable_type}:#{pg.pageable_id} chars=#{h.length} bytes=#{h.bytesize}"
puts "PRE_SHA=#{Digest::SHA256.hexdigest(h)}"
puts "STYLE_OPEN=#{h.scan('<style').size} STYLE_CLOSE=#{h.scan('</style>').size} SCRIPT=#{h.scan('<script').size}"
puts "MAIN=#{h.scan('</main>').size} OPENMAIN=#{h.scan('<main').size} BODYCLOSE=#{h.scan('</body>').size}"
puts "TAIL=#{h[-460..].inspect}"
puts "HEAD=#{h[0, 220].inspect}"
h.scan(/<style[^>]*>/).each_with_index { |s, i| puts "STYLE_TAG#{i}=#{s}" }
%w[multiplex-card mx-peek .multiplex-viewport .grid aspect-ratio object-fit].each do |k|
  puts "COUNT #{k} = #{h.scan(k).size}"
end
puts "PAGES=#{Page.where(pageable_type: 'User', pageable_id: u.id).order(:id).map { |p| [p.id, p.slug, p.custom_html.to_s.length].inspect }.join(' ')}"
puts "DONE"
