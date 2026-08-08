# frozen_string_literal: true

class ScheduleAffiliateWorkflowJobsJob
  class AffiliateNotCommittedError < StandardError; end

  include Sidekiq::Job
  sidekiq_options retry: 10, queue: :low

  def perform(affiliate_id, product_affiliate_id)
    ActiveRecord::Base.connection.stick_to_primary!
    affiliate = DirectAffiliate.alive.find_by(id: affiliate_id)
    product_affiliate = ProductAffiliate.find_by(id: product_affiliate_id, affiliate_id:)
    raise AffiliateNotCommittedError if affiliate.nil? || product_affiliate.nil?
    return unless affiliate.send_posts

    affiliate.schedule_workflow_jobs(triggering_product_affiliates: [product_affiliate])
  ensure
    Makara::Context.release_all
  end
end
