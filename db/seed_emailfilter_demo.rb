# db/seed_emailfilter_demo.rb — inspect seeded seller + products
u = User.find_by(email: "seller@example.com") || User.joins(:links).group("users.id").order("COUNT(links.id) DESC").first
puts "SELLER: id=#{u.id} email=#{u.email} username=#{u.username}"
puts "confirmed=#{u.confirmed_at.present?} 2fa=#{u.two_factor_authentication_enabled?}"
alive = u.links.alive.to_a
puts "alive products=#{alive.size}"
simple = alive.select { |l| !l.is_recurring_billing && l.variant_categories.empty? && l.price_cents.to_i > 0 }
puts "SIMPLE products (non-recurring, no variants, priced):"
simple.first(6).each { |l| puts "  #{l.id} | #{l.unique_permalink} | $#{l.price_cents/100.0} | #{l.name[0,40]}" }
# audience now?
require "set"
puts "customer audience_members now: #{u.audience_members.where(customer: true).count}"
