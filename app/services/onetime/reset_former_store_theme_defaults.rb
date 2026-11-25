# frozen_string_literal: true

module Onetime
  # Stores used to default to small corners and a lifting button, and any save wrote those defaults
  # into the row. Clearing them lets such stores follow the current defaults (medium, no lift). A
  # seller who chose either on purpose cannot be told apart, and can pick it again in settings.
  # Safe to rerun. Run with dry_run: true first to see the counts.
  class ResetFormerStoreThemeDefaults
    BATCH_SIZE = 1_000
    FORMER_DEFAULTS = { border_radius: "small", button_hover: "lift" }.freeze

    def self.process(...)
      new.process(...)
    end

    def process(dry_run: true, batch_size: BATCH_SIZE)
      reset = FORMER_DEFAULTS.transform_values { 0 }

      SellerProfile.in_batches(of: batch_size) do |batch|
        ReplicaLagWatcher.watch

        FORMER_DEFAULTS.each do |column, former_default|
          profiles = batch.where(column => former_default)
          if dry_run
            reset[column] += profiles.count
          else
            cache_names = profiles.includes(:seller).map(&:custom_style_cache_name)
            reset[column] += profiles.update_all(column => nil, updated_at: Time.current)
            # update_all skips the callback that clears the store's compiled CSS.
            cache_names.each { Rails.cache.delete(_1) }
          end
        end
      end

      puts "[#{self.class.name}] #{dry_run ? "would reset" : "reset"} #{reset}"
      reset
    end
  end
end
