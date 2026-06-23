# db/seed_emailfilter_login.rb — set known pw + verify Sales page data
u = User.find_by!(email: "seller@example.com")
u.update_columns(confirmed_at: Time.current) if u.confirmed_at.blank?
u.password = "Gx7-quetzal-Vault-39"
u.save!(validate: false)
puts "PW SET for #{u.email}"

# how many successful sales (drives /customers rows)
cnt = Purchase.where(seller_id: u.id, purchase_state: "successful").count
puts "successful purchases (DB): #{cnt}"

# ES purchases index count for this seller
begin
  es = Purchase.__elasticsearch__.client
  total = es.count(index: Purchase.index_name)["count"]
  puts "ES #{Purchase.index_name} total docs: #{total}"
rescue => e
  puts "ES check error: #{e.class}: #{e.message}"
end

# product permalinks to demo filters with
ps = u.links.alive.select { |l| !l.is_recurring_billing && l.variant_categories.empty? && l.price_cents.to_i > 0 }.first(3)
ps.each { |l| puts "DEMO_PRODUCT #{l.unique_permalink} | #{l.name[0,40]}" }
