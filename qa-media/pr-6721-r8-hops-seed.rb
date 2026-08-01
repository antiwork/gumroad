# frozen_string_literal: true

# Renames real rows, so refuse to run anywhere but a preview pod.
abort("staging only — this script renames products and writes legacy_permalinks") unless Rails.env.staging?

# Product 5 is the one the concurrent sibling session is not touching; assert before mutating,
# since a reseed can renumber the fixtures out from under this id.
RUN = "r126656"
l = Link.find(5)
abort("unexpected seed state: product 5 is user #{l.user_id}, expected 9") unless l.user_id == 9
puts "MARK product=#{l.id} user=#{l.user_id} host=#{l.user.subdomain_with_protocol} custom_before=#{l.custom_permalink.inspect}"

a = "yhop-a-#{RUN}"; b = "yhop-b-#{RUN}"; c = "yhop-c-#{RUN}"
[a, b, c].each { |s| LegacyPermalink.where(permalink: s).delete_all }

l.update!(custom_permalink: a)
puts "MARK set_initial live=#{l.reload.custom_permalink} rows=#{LegacyPermalink.where(product_id: l.id).pluck(:permalink).sort.inspect}"
l.update!(custom_permalink: b)
l.update!(custom_permalink: c)
puts "MARK hops_done live=#{l.reload.custom_permalink} rows=#{LegacyPermalink.where(product_id: l.id).pluck(:permalink).sort.inspect}"

[a, b, c].each do |s|
  scoped = Link.fetch_leniently(s, user: l.user) rescue "ERR"
  unscoped = Link.fetch_leniently(s) rescue "ERR"
  puts "MARK resolve slug=#{s} scoped=#{scoped.respond_to?(:id) ? scoped.id : scoped} unscoped=#{unscoped.respond_to?(:id) ? unscoped.id : unscoped} expected=#{l.id}"
end
puts "MARK host=#{l.user.subdomain_with_protocol} name=#{l.name.inspect} live_url=#{l.long_url}"
puts "MARK DONE"
