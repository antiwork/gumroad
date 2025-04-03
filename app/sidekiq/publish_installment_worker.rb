# frozen_string_literal: true

# Deprecated
# TODO (chris): remove this class once...
# - all AudienceMembers have been populated
# - all scheduled jobs have been processed
class PublishInstallmentWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default, lock: :until_executed

  def perform(installment_id, blast_id = nil, version = 0)
    installment = Installment.find(installment_id)
    return unless installment.alive?

    if blast_id
      SendPostBlastEmailsJob.perform_async(blast_id)
    else
      PublishScheduledPostJob.perform_async(installment_id, version)
    end
  end
end
