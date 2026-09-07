# typed: strict
# frozen_string_literal: true

# One-off migration (gumroad-private#2433): move :gumhead beta membership from
# Flipper per-actor enablement (capped at 100 actors by flipper 1.3) to the
# User#gumhead_enabled flag bit, and gate :gumhead through the :gumhead_beta
# group registered in config/initializers/feature_toggle.rb. Idempotent: a
# re-run after a partial failure only sets bits for creator actors still on the
# feature and re-enables the group; it never clears a bit set by a later
# rollout tick. Run once on prod, then the rollout watch switches to setting
# the bit instead of Feature.activate_user.
desc "Migrate :gumhead Flipper actors to the gumhead_enabled flag-bit group"
task migrate_gumhead_to_flag_group: :environment do
  feature = Flipper[:gumhead]
  group = :gumhead_beta

  # Flipper actor strings are "<Class>;<id>"; only real User ids migrate.
  actor_ids = feature.actors_value.filter_map do |actor|
    id = actor.to_s.split(";").last.to_i
    id if id.positive?
  end.uniq

  migrated = 0
  actor_ids.each_slice(500) do |ids|
    User.where(id: ids).find_each do |user|
      next if user.gumhead_enabled?
      user.update!(gumhead_enabled: true)
      migrated += 1
    end
  end

  # Enable the group gate after the bits are set, so no creator who is already
  # on the beta loses access between the bit write and the group flip.
  Flipper.enable_group(:gumhead, group) unless feature.enabled_groups.include?(Flipper.group(group))

  # Clear the now-redundant per-actor entries so the actor count no longer
  # presses against flipper 1.3's 100-actor cap. Actors are removed by id so
  # the group gate takes over cleanly.
  actor_ids.each_slice(500) do |ids|
    User.where(id: ids).find_each { |user| Flipper.disable_actor(:gumhead, user) }
  end

  puts "migrate_gumhead_to_flag_group: actors=#{actor_ids.size} bits_set=#{migrated} group_enabled=#{feature.groups_value.include?('gumhead_beta')} actors_remaining=#{feature.actors_value.size}"
end