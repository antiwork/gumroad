# frozen_string_literal: true

# Cross-seller contention leg for gumroad#6721 / gumroad-private#1653.
# A DIFFERENT seller claims, LIVE, the slug that seller@'s legacy mapping holds.
# Before the reorder the bare domain served the MAPPED product (wrong seller).
# After it, the live claimant must win, and the mapping row must survive untouched.
SLUG = "xseller-old-974496"

owner = User.find_by(email: "seller@gumroad.com")
claimant = User.find_by(email: "gumbo_film@gumroad.com")
puts "MARK owner=#{owner.id} claimant=#{claimant.id}"

lp = LegacyPermalink.find_by(permalink: SLUG)
mapped = Link.find_by(id: lp&.product_id)
puts "MARK mapping_exists=#{!lp.nil?} product=#{lp&.product_id} owner=#{mapped&.user_id} alive=#{mapped&.alive?}"
puts "MARK before_bare=#{Link.fetch_leniently(SLUG)&.id} " \
     "before_bare_owner=#{Link.fetch_leniently(SLUG)&.user_id}"

target = claimant.links.alive.first
puts "MARK claimant_product=#{target&.id} current_slug=#{target&.custom_permalink} url=#{target&.long_url}"

# The claim itself, through the model (the writer callback fires on this save).
target.update!(custom_permalink: SLUG)
target.reload
puts "MARK after_claim slug=#{target.custom_permalink} alive=#{target.alive?}"

lp2 = LegacyPermalink.find_by(permalink: SLUG)
puts "MARK mapping_survived=#{!lp2.nil?} still_points_at=#{lp2&.product_id} " \
     "unchanged=#{lp2&.product_id == lp&.product_id}"

resolved = Link.fetch_leniently(SLUG)
puts "MARK after_bare=#{resolved&.id} after_bare_owner=#{resolved&.user_id} " \
     "is_claimant=#{resolved&.user_id == claimant.id}"
puts "MARK claimant_long_url=#{target.long_url}"
puts "MARK mapped_long_url=#{mapped&.long_url}"
