# frozen_string_literal: true

class Onetime::BackfillLegacyFeatureAnnouncementPreferences
  BATCH_SIZE = 1_000
  MAX_BATCHES = 100
  MAX_RUN_SECONDS = 90
  SOURCE = "legacy_announcements_migration"

  # Keep the fence fixed between calls. After a failure, replay the last successful cursor.
  # The runtime limit is cooperative; the caller must bound SQL and lock waits separately.
  def self.process(upper_user_id:, after_user_id: 0, batch_size: BATCH_SIZE, max_batches: 1, max_run_seconds: 30, dry_run: true)
    new.process(upper_user_id:, after_user_id:, batch_size:, max_batches:, max_run_seconds:, dry_run:)
  end

  def process(upper_user_id:, after_user_id:, batch_size:, max_batches:, max_run_seconds:, dry_run:)
    { upper_user_id: [upper_user_id, 1, 2**63 - 1], after_user_id: [after_user_id, 0, upper_user_id],
      batch_size: [batch_size, 1, BATCH_SIZE], max_batches: [max_batches, 1, MAX_BATCHES] }.each do |name, (value, minimum, maximum)|
      raise ArgumentError, "Invalid #{name}" unless value.is_a?(Integer) && maximum.is_a?(Integer) && value.between?(minimum, maximum)
    end
    unless max_run_seconds.is_a?(Numeric) && max_run_seconds.real? && max_run_seconds.finite? && max_run_seconds > 0 && max_run_seconds <= MAX_RUN_SECONDS
      raise ArgumentError, "Invalid max_run_seconds"
    end
    raise ArgumentError, "Invalid dry_run" unless [true, false].include?(dry_run)

    deadline = monotonic_time + max_run_seconds
    result = { dry_run:, upper_user_id:, cursor: after_user_id, scanned: 0, candidates: 0, preserved: 0,
               legacy_off: 0, missing_users: 0, attempted: 0, observed_source_rows: 0, inserted: dry_run ? 0 : nil,
               inserted_count_known: dry_run, preserved_scope: "observed_before_insert", batches: 0, exhausted: after_user_id == upper_user_id }
    ApplicationRecord.connected_to(role: :writing) do
      ApplicationRecord.uncached do
        raise ArgumentError, "Apply requires no ambient transaction" if !dry_run && ApplicationRecord.connection.transaction_open?

        while !result[:exhausted] && result[:batches] < max_batches && monotonic_time < deadline
          ReplicaLagWatcher.watch(deadline:) unless dry_run
          break if monotonic_time >= deadline

          # Page raw primary keys before inspecting the flag, including rows whose flag is off.
          rows = User.unscoped.where(id: (result[:cursor] + 1)..upper_user_id).order(:id).limit(batch_size).pluck(:id, :flags)
          break if monotonic_time >= deadline

          counts = if dry_run
            classify(rows)
          else
            insert_preferences(rows.map(&:first))
          end
          counts.each { |name, count| result[name] += count }
          result[:scanned] += rows.size
          result[:cursor] = rows.last.first if rows.any?
          result[:batches] += 1
          result[:exhausted] = result[:cursor] == upper_user_id || rows.size < batch_size
        end
      end
    end
    result
  end

  private
    def classify(rows)
      existing = FeatureAnnouncementSubscription.where(user_id: rows.map(&:first)).pluck(:user_id).to_set
      announcement_flag = User.flag_mapping["flags"].fetch(:announcement_notification_enabled)
      candidates, legacy_off = rows.reject { |id, _| existing.include?(id) }.partition { |_, flags| (flags.to_i & announcement_flag).positive? }
      yield candidates.map(&:first) if block_given?
      { candidates: candidates.size, preserved: existing.size, legacy_off: legacy_off.size }
    end

    def insert_preferences(ids)
      User.transaction do
        rows = User.unscoped.where(id: ids).order(:id).lock("FOR SHARE").pluck(:id, :flags)
        counts = classify(rows) do |candidates|
          # MySQL skips duplicate keys atomically. It cannot report an exact inserted count here.
          FeatureAnnouncementSubscription.insert_all(candidates.map { |id| { user_id: id, subscribed: true, source: SOURCE } }) if candidates.any?
        end
        counts.merge(missing_users: ids.size - rows.size, attempted: counts[:candidates],
                     observed_source_rows: FeatureAnnouncementSubscription.where(user_id: ids, source: SOURCE).count)
      end
    end

    def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
