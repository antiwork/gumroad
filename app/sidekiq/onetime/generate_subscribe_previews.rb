# frozen_string_literal: true

class Onetime::GenerateSubscribePreviews
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :mongo

  def perform(user_ids)
    users = User.where(id: user_ids)
    subscribe_previews = SubscribePreviewGeneratorService.generate_pngs(users)

    if subscribe_previews.length != users.length || users.any?(&:nil?)
      raise "Failed to generate all subscribe previews for top sellers"
    end

    users.each_with_index do |user, i|
      user.subscribe_preview.attach(
        io: StringIO.new(subscribe_previews[i]),
        filename: "subscribe_preview.png",
        content_type: "image/png"
      )
      user.subscribe_preview.blob.save!
    end
  end
end
