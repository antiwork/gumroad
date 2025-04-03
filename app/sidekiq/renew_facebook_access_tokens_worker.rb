# frozen_string_literal: true

class RenewFacebookAccessTokensWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :critical

  def perform
    users = User.where("updated_at > ? AND facebook_access_token IS NOT NULL", Date.today - 30)

    users.find_each do |user|
      user.renew_facebook_access_token
      user.save
    end
  end
end
