l = Link.find_by(unique_permalink: "mfhpmi")
puts "link_id=#{l.id} pageable=nil"
pg = Page.where(pageable: l).first rescue nil
puts "page_id=#{pg && pg.id} pageable_type=#{pg && pg.pageable_type}/#{pg && pg.pageable_id}"
puts "link_custom_html_len=#{l.custom_html.to_s.length}"
puts "page_custom_html_len=#{pg && pg.custom_html.to_s.length}"
puts "page_writable_has_col=#{(pg && pg.class.column_names.include?('custom_html')) || false}"
puts "feature_custom_html_pages=#{Feature.active?(:custom_html_pages, l.user)}"
puts "purchase_disabled_at=#{l.purchase_disabled_at.inspect}"
puts "price_cents=#{l.price_cents} currency=#{l.currency_type}"
puts "suspended=#{l.user.suspended?}"
