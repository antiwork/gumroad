# frozen_string_literal: true

# Resizes a new avatar off the request, so the first page view after an upload serves a stored variant.
class GenerateAvatarVariantJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low, lock: :until_executed

  def perform(user_id)
    User.find_by(id: user_id)&.avatar_variant
  rescue ActiveStorage::FileNotFoundError
    # The upload itself is gone from storage, so no retry can resize it.
  end
end
