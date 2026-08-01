# frozen_string_literal: true

abort("staging only") unless Rails.env.staging? || ENV["BRANCH_DEPLOYMENT"].present?

NONCE = "r6721b"
SHARED = "zshared-#{NONCE}"
MOVED  = "zmoved-#{NONCE}"

renamer  = Link.find(6)  # gumboeducation, user 10
claimant = Link.find(7)  # gumbosoftware,  user 11

abort("fixture moved") unless renamer.user_id == 10 && claimant.user_id == 11

ProductPermalinkRedirect.where(permalink: [SHARED, MOVED]).delete_all
LegacyPermalink.where(permalink: [SHARED, MOVED]).delete_all

claimant.update!(custom_permalink: SHARED)
renamer.update!(custom_permalink: SHARED)
puts "MARK armed renamer=#{renamer.reload.custom_permalink} claimant=#{claimant.reload.custom_permalink}"
puts "MARK ppr_before=#{ProductPermalinkRedirect.where(permalink: SHARED).map { [_1.seller_id, _1.product_id] }.inspect}"

renamer.update!(custom_permalink: MOVED)

puts "MARK ppr_after=#{ProductPermalinkRedirect.where(permalink: SHARED).map { [_1.seller_id, _1.product_id] }.inspect}"
puts "MARK legacy_after=#{LegacyPermalink.where(permalink: SHARED).map(&:product_id).inspect}"
puts "MARK resolve_renamer_host=#{Link.fetch_leniently(SHARED, user: renamer.user)&.id}  expected=6"
puts "MARK resolve_claimant_host=#{Link.fetch_leniently(SHARED, user: claimant.user)&.id} expected=7"
puts "MARK resolve_bare=#{Link.fetch_leniently(SHARED)&.id} expected=7"
puts "MARK urls renamer_old=#{renamer.user.subdomain_with_protocol}/l/#{SHARED} renamer_new=#{renamer.user.subdomain_with_protocol}/l/#{MOVED} claimant=#{claimant.user.subdomain_with_protocol}/l/#{SHARED}"
puts "MARK names renamer=#{renamer.name.inspect} claimant=#{claimant.name.inspect}"
puts "MARK alive renamer_alive=#{renamer.alive?} claimant_alive=#{claimant.alive?}"
