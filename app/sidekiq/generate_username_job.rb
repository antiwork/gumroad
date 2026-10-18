# frozen_string_literal: true

class GenerateUsernameJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(user_id)
    user = User.find(user_id)
    return if user.read_attribute(:username).present?

    username = UsernameGeneratorService.new(user).username
    return if username.nil?
    # Leave the account on its default username rather than fail the save and retry.
    return if BlockedUsernameValidator.blocked_for?(username, user)

    user.with_lock do
      break if user.read_attribute(:username).present?
      user.update!(username:)
    end
  end
end
