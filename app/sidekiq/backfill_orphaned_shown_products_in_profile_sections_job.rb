# frozen_string_literal: true

# Off-deploy replacement for the inline backfill that used to live in migration
# 20261201000005. Enqueue manually when ready to run the cleanup:
#   BackfillOrphanedShownProductsInProfileSectionsJob.perform_async
class BackfillOrphanedShownProductsInProfileSectionsJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 5, lock: :until_executed

  def perform
    Onetime::BackfillOrphanedShownProductsInProfileSections.process
  end
end
