# frozen_string_literal: true

class GenerateUsernameJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(user_id)
    user = User.find(user_id)
    return if user.read_attribute(:username).present?

    username = UsernameGeneratorService.new(user).username
    return if username.nil?

    user.with_lock do
      break if user.read_attribute(:username).present?
      user.update!(username:)
    end
  end
end
