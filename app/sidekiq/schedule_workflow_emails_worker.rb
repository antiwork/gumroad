# frozen_string_literal: true

class ScheduleWorkflowEmailsWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(purchase_id)
    purchase = Purchase.find(purchase_id)
    purchase.schedule_all_workflows
  end
end
