# db/seed_emailfilter_reindex.rb — index this seller's purchases into ES
u = User.find_by!(email: "seller@example.com")
ps = Purchase.where(seller_id: u.id, purchase_state: "successful")
puts "indexing #{ps.count} purchases..."
n = 0
ps.find_each do |p|
  begin
    p.__elasticsearch__.index_document
    n += 1
  rescue => e
    puts "skip #{p.id}: #{e.class}"
  end
end
Purchase.__elasticsearch__.refresh_index!
puts "indexed=#{n}"
total = Purchase.__elasticsearch__.client.count(index: Purchase.index_name)["count"]
puts "ES purchases total now: #{total}"
