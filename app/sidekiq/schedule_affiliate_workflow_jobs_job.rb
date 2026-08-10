# frozen_string_literal: true

class ScheduleAffiliateWorkflowJobsJob
  include Sidekiq::Job
  sidekiq_options retry: 10, queue: :low

  def perform(workflow_schedule_token = nil)
    ActiveRecord::Base.connection.stick_to_primary!
    if workflow_schedule_token.nil?
      dispatch_pending
      return
    end

    product_affiliates = ProductAffiliate.where(workflow_schedule_token:).includes(:affiliate, :product).to_a
    return if product_affiliates.empty?

    product_affiliates.group_by(&:affiliate).each do |affiliate, assignments|
      next if !affiliate.is_a?(DirectAffiliate) || affiliate.deleted? || !affiliate.send_posts

      affiliate.schedule_workflow_jobs(triggering_product_affiliates: assignments)
    end
    ProductAffiliate.where(workflow_schedule_token:).update_all(workflow_schedule_token: nil)
  ensure
    Makara::Context.release_all
  end

  private
    def dispatch_pending
      ProductAffiliate.where.not(workflow_schedule_token: nil)
        .group(:workflow_schedule_token)
        .minimum(:id)
        .each_key do |token|
          next unless ProductAffiliate.workflow_schedule_dispatchable?(token)

          ProductAffiliate.enqueue_workflow_schedule(token)
        end
    end
end
