M = "KBS25X"
u = User.unscoped.find_by(email: "icytigress69@gmail.com")
pk = u.id
ps = Purchase.unscoped.where(purchaser_id: pk)
puts "#{M} pk=#{pk} n=#{ps.count} created=#{u.created_at.to_date} username=#{u.username.inspect}"
puts "#{M} ipctry=#{ps.group(:ip_country).count.sort_by { |_k, v| -v }.first(6).inspect}"
puts "#{M} zip=#{ps.group(:zip_code).count.sort_by { |_k, v| -v }.first(6).inspect}"
puts "#{M} cards=#{ps.distinct.pluck(:card_visual).compact.inspect}"
puts "#{M} states=#{ps.group(:purchase_state).count.inspect}"
puts "#{M} statesX=#{ps.group(:state).count.inspect}"
begin
  puts "#{M} locked=#{ps.where(is_reassignment_locked: true).count}"
rescue => e
  puts "#{M} locked_err=#{e.class}"
end
begin
  puts "#{M} reviews=#{ProductReview.where(purchase_id: ps.pluck(:id)).count}"
rescue => e
  puts "#{M} reviews_err=#{e.class}"
end
begin
  puts "#{M} follows=#{Follower.where(email: "icytigress69@gmail.com").count}"
rescue => e
  puts "#{M} follows_err=#{e.class}"
end
puts "#{M} --- jan2022 rows"
ps.where("created_at >= ? and created_at < ?", Time.utc(2022, 1, 1), Time.utc(2022, 3, 1)).order(:created_at).limit(12).each do |p|
  puts "#{M} R|#{p.created_at.strftime('%Y-%m-%d %H:%M')}|#{p.price_cents}|#{p.total_transaction_cents}|#{p.card_visual.inspect}|#{p.card_type.inspect}|#{p.zip_code.inspect}|#{p.ip_country.inspect}|#{p.link_id}"
end
puts "#{M} --- recent stripe rows card expiry"
ps.where(charge_processor_id: "stripe").order(created_at: :desc).limit(8).each do |p|
  cc = p.credit_card
  puts "#{M} E|#{p.created_at.strftime('%Y-%m-%d')}|card=#{p.card_visual.inspect}|exp=#{cc && cc.expiry_month}/#{cc && cc.expiry_year}"
end
puts "#{M} DONE"