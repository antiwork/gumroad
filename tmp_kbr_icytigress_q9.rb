M = "KBR25X"
u = User.unscoped.find_by(email: "icytigress69@gmail.com")
pk = u.id
sc = Purchase.where(purchaser_id: pk)
puts "#{M} pk=#{pk} n_pid=#{sc.count} n_email=#{Purchase.where(email: 'icytigress69@gmail.com').count} n_email_unscoped=#{Purchase.unscoped.where(email: 'icytigress69@gmail.com').count}"
puts "#{M} names=#{sc.distinct.pluck(:full_name).compact.first(8).inspect}"
puts "#{M} zips=#{sc.distinct.pluck(:zip_code).compact.first(8).inspect}"
puts "#{M} cardzips=#{sc.distinct.pluck(:credit_card_zipcode).compact.first(8).inspect}"
puts "#{M} cards=#{sc.distinct.pluck(:card_visual).compact.size} distinct"
puts "#{M} mid=#{sc.order(:created_at).offset(sc.count / 2).limit(1).map { |p| p.created_at.strftime('%Y-%m') }.inspect}"
puts "#{M} range=#{sc.minimum(:created_at).inspect}..#{sc.maximum(:created_at).inspect}"
puts "#{M} titles2025=n/a"
titles = Purchase.joins("JOIN links l ON l.id = purchases.link_id").where("purchases.purchaser_id = ?", pk).order("purchases.created_at DESC").limit(12).pluck("purchases.created_at", "l.name")
titles.each { |t, n| puts "#{M} T|#{t.strftime('%Y-%m-%d')}|#{n.to_s[0, 70]}" }
puts "#{M} DONE"
