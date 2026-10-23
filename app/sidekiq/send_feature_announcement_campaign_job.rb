# frozen_string_literal: true

# Enqueues one FeatureAnnouncementMailer email per subscribed account, a batch per run. The handoff
# gate decides who actually gets it, so a retried batch that enqueues an account twice sends once.
class SendFeatureAnnouncementCampaignJob
  include Sidekiq::Job
  sidekiq_options queue: :low, lock: :until_executed, retry: 5

  BATCH_SIZE = 1_000

  # Reads go to the primary: a lagging replica could end the send early, miss a fresh opt-in, or
  # pass an old address that the gate then skips for good as a recipient mismatch.
  def perform(campaign_id, after_subscription_id = 0)
    ApplicationRecord.connected_to(role: :writing) { enqueue_batch(campaign_id, after_subscription_id) }
  end

  private
    def enqueue_batch(campaign_id, after_subscription_id)
      campaign = FeatureAnnouncementCampaign.find(campaign_id)
      return unless campaign.state == "sending"

      batch = FeatureAnnouncementSubscription.where(subscribed: true).where("id > ?", after_subscription_id)
        .order(:id).limit(BATCH_SIZE).pluck(:id, :user_id)
      User.where(id: batch.map(&:last)).pluck(:id, :email).each do |user_id, email|
        FeatureAnnouncementMailer.announcement(campaign: campaign.key, user_id:, email:).deliver_later(queue: "low")
      end

      if batch.size == BATCH_SIZE
        self.class.perform_async(campaign_id, batch.last.first)
      else
        FeatureAnnouncementCampaign.where(id: campaign_id, state: "sending").update_all(state: "sent", updated_at: Time.current)
      end
    end
end
