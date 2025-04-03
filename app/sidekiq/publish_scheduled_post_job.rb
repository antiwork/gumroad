# frozen_string_literal: true

class PublishScheduledPostJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(post_id, version)
    post = Installment.find(post_id)

    post.with_lock do
      return unless post.alive? # post may have been deleted
      return if post.published? # no need to try to publish it again or send emails

      rule = post.installment_rule
      return unless version == rule.version # the version may have changed (e.g. the post was rescheduled)
      return unless rule.alive? # the rule may have been deleted (happens when the post is published)

      post.publish!

      if post.can_be_blasted?
        blast = PostEmailBlast.create!(post:, requested_at: rule.to_be_published_at)
        SendPostBlastEmailsJob.perform_async(blast.id)
      end
    end
  end
end
