# frozen_string_literal: true

class GenerateSubscribePreviewJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform(user_id)
    user = User.find(user_id)

    image = SubscribePreviewGeneratorService.generate_pngs([user]).first

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
