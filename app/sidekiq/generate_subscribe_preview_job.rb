# frozen_string_literal: true

class GenerateSubscribePreviewJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  # Normal attempts insist on the avatar, so a slow CDN gets another try rather
  # than permanently attaching a card with an empty circle. Once retries run out,
  # settle for an avatar-less card over leaving the seller with none at all.
  sidekiq_retries_exhausted do |msg, _exception|
    new.perform(*msg["args"], require_avatar: false)
  end

  def perform(user_id, require_avatar: true)
    user = User.find(user_id)

    image = SubscribePreviewGeneratorService.generate_pngs([user], require_avatar:).first

    if image.blank?
      raise "Subscribe Preview could not be generated for user.id=#{user.id}"
    end

    user.subscribe_preview.attach(
      io: StringIO.new(image),
      filename: "subscribe_preview.png",
      content_type: "image/png"
    )

    user.subscribe_preview.blob.save!
  end
end
