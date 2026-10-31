u = User.find_by(email: "garveyindustry5@gmail.com")
raise "no user" unless u
puts "USER #{u.id} ext=#{u.external_id} username=#{u.username} suspended=#{u.suspended?}"
puts "FEATURE custom_html_pages=#{Feature.active?(:custom_html_pages, u)}"
l = Link.find_by(id: Link.where(unique_permalink: "qkicyh").pluck(:id).first)
l = Link.where(unique_permalink: "qkicyh").first
raise "no link" unless l
puts "LINK id=#{l.id} perm=#{l.custom_permalink} unique=#{l.unique_permalink} alive=#{l.alive?} price=#{l.price_cents} currency=#{l.price_currency_type} customizable=#{l.customizable_price}"
puts "LINK custom_html len=#{l.custom_html.to_s.length}"
ppages = Page.where(pageable_type: "Link", pageable_id: l.id).pluck(:id, :slug)
puts "LINK_PAGES #{ppages.inspect}"
upages = Page.where(pageable_type: "User", pageable_id: u.id).pluck(:id, :slug)
puts "USER_PAGES #{upages.inspect}"
puts "USER custom_html len=#{u.custom_html.to_s.length}"
puts "AVATAR #{u.avatar_url}"
puts "PREVIEWS #{l.asset_previews.alive.map { |p| [p.id, p.url, p.attributes["width"], p.attributes["height"]] }.inspect}"
puts "DESC_LEN #{l.description.to_s.length}"
puts "TAGS #{l.tags.inspect}"
