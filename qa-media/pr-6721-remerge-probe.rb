# frozen_string_literal: true

RUN = "r#{rand(100000..999999)}"
seller = User.find_by(email: "seller@gumroad.com")
puts "MARK seller=#{seller.id} #{seller.subdomain_with_protocol}"
puts "MARK code_present after_save=#{Link.instance_variable_get(:@__callbacks) ? 'n/a' : 'n/a'}"
puts "MARK writer_methods=#{(Link.private_instance_methods + Link.instance_methods).grep(/permalink/).sort.inspect}"

l = Link.where(user_id: seller.id).alive.first
puts "MARK product=#{l.id} name=#{l.name.inspect} start_custom=#{l.custom_permalink.inspect}"

a = "hop-a-#{RUN}"; b = "hop-b-#{RUN}"; c = "hop-c-#{RUN}"

l.update!(custom_permalink: a)
puts "MARK set_initial=#{l.reload.custom_permalink} legacy_rows=#{LegacyPermalink.where(product_id: l.id).pluck(:permalink).inspect}"

l.update!(custom_permalink: b)
puts "MARK hop1=#{l.reload.custom_permalink} legacy_rows=#{LegacyPermalink.where(product_id: l.id).pluck(:permalink).inspect}"

l.update!(custom_permalink: c)
puts "MARK hop2=#{l.reload.custom_permalink} legacy_rows=#{LegacyPermalink.where(product_id: l.id).pluck(:permalink).sort.inspect}"

[a, b, c].each do |slug|
  scoped = Link.fetch_leniently(slug, user: seller) rescue "ERR:#{$!.class}"
  unscoped = Link.fetch_leniently(slug) rescue "ERR:#{$!.class}"
  puts "MARK resolve slug=#{slug} scoped=#{scoped.respond_to?(:id) ? scoped.id : scoped.inspect} unscoped=#{unscoped.respond_to?(:id) ? unscoped.id : unscoped.inspect} expected=#{l.id}"
end

puts "MARK urls a=#{seller.subdomain_with_protocol}/l/#{a} b=#{seller.subdomain_with_protocol}/l/#{b} c=#{seller.subdomain_with_protocol}/l/#{c}"
puts "MARK RUN=#{RUN}"
