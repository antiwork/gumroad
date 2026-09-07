# typed: strict
# frozen_string_literal: true

# Idempotent: a re-run only sets bits for actors still on the feature and
# re-enables the group; it never clears a bit set by a later rollout tick.
desc "Migrate :gumhead Flipper actors to the gumhead_enabled flag-bit group"
task migrate_gumhead_to_flag_group: :environment do
  feature = Flipper[:gumhead]
  group = :gumhead_beta

  # Flipper actor strings are "<Class>;<id>"; only User actors migrate.
  actor_ids = feature.actors_value.filter_map do |actor|
    klass, id = actor.to_s.split(";", 2)
    id.to_i if klass == "User" && id.to_i.positive?
  end.uniq

  migrated = 0
  actor_ids.each_slice(500) do |ids|
    User.where(id: ids).find_each do |user|
      next if user.gumhead_enabled?
      user.update!(gumhead_enabled: true)
      migrated += 1
    end
  end

  # Bits must be set before the group flips on, or members briefly lose access.
  Flipper.enable_group(:gumhead, group) unless feature.enabled_groups.include?(Flipper.group(group))

  # Clear per-actor entries so the count stops pressing the 100-actor cap.
  actor_ids.each_slice(500) do |ids|
    User.where(id: ids).find_each { |user| Flipper.disable_actor(:gumhead, user) }
  end

  puts "migrate_gumhead_to_flag_group: actors=#{actor_ids.size} bits_set=#{migrated} group_enabled=#{feature.groups_value.include?('gumhead_beta')} actors_remaining=#{feature.actors_value.size}"
end
