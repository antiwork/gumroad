# frozen_string_literal: true

# Renames real rows, so refuse to run anywhere but a preview pod.
abort("staging only — this script renames products and writes legacy_permalinks") unless Rails.env.staging?

# Pick a contention pair the concurrent sibling session is NOT touching (it owns products 1 and 3).
RUN = "r126656"
busy = [1, 3]
cands = Link.alive.where.not(id: busy).order(:id).limit(40).to_a
puts "MARK candidates=#{cands.map { |l| [l.id, l.user_id] }.inspect}"

owner_a = Link.find(1).user_id
b = cands.find { |l| l.user_id != owner_a } || cands.first
puts "MARK chosen_liveB=#{b.id} user=#{b.user_id} host=#{b.user.subdomain_with_protocol} custom_was=#{b.custom_permalink.inspect}"

mapped_target = cands.find { |l| l.id != b.id && l.user_id != b.user_id } || Link.find(1)
puts "MARK mapped_target=#{mapped_target.id} user=#{mapped_target.user_id}"

slug = "xcontend-#{RUN}"
LegacyPermalink.where(permalink: slug).delete_all
LegacyPermalink.create!(permalink: slug, product_id: mapped_target.id)
b.update!(custom_permalink: slug)

puts "MARK armed slug=#{slug} mapping->#{LegacyPermalink.find_by(permalink: slug).product_id} live_holder=#{b.reload.id}"
puts "MARK live_scope=#{Link.by_user(nil).visible.by_general_permalink(slug).pluck(:id).inspect}"
r = Link.fetch_leniently(slug)
puts "MARK bare_resolves=#{r&.id} LIVE_FIRST_OK=#{r&.id == b.id} (mapped_would_be=#{mapped_target.id})"
puts "MARK liveB_url=#{b.long_url} liveB_name=#{b.name.inspect}"
puts "MARK mappedA_url=#{mapped_target.long_url} mappedA_name=#{mapped_target.name.inspect}"
puts "MARK DONE"
