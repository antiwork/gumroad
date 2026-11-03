# frozen_string_literal: true

# Resumes imports whose job stopped without finishing, for example after a worker was killed. The
# import job's lock drops a duplicate, and the job skips the products already imported.
class ResumeStalledPartnerMigrationsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform
    ApplicationRecord.connected_to(role: :writing) do
      PartnerMigration.stalled.select(:id).find_each do |migration|
        migration.resume_stalled_import!
      end
    end
  end
end
