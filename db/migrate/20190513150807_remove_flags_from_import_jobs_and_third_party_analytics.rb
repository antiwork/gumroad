# frozen_string_literal: true

class RemoveFlagsFromImportJobsAndThirdPartyAnalytics < ActiveRecord::Migration
  def change
    remove_column :import_jobs, :flags
    remove_column :third_party_analytics, :flags
  end
end
