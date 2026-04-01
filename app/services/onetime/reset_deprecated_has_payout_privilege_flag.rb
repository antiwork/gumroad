# frozen_string_literal: true

class Onetime::ResetDeprecatedHasPayoutPrivilegeFlag
  def self.reset!
    User.where(User.has_dismissed_getting_started_checklist_condition).find_in_batches do |batch|
      ReplicaLagWatcher.watch
      puts batch.first.id
      User.where(id: batch.map(&:id)).update_all(User.set_flag_sql(:has_dismissed_getting_started_checklist, false))
    end
  end
end
