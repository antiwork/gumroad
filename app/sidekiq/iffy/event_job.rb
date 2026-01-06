# frozen_string_literal: true

class Iffy::EventJob
  include Sidekiq::Job

  sidekiq_options retry: 3, queue: :default

  RECENT_PURCHASE_PERIOD = 1.year
  EVENTS = %w[
    user.banned
    user.suspended
    user.compliant
    record.flagged
    record.compliant
  ]

  def perform(event, id, entity, user = nil)
    return unless event.in?(EVENTS)

    case event
    when "user.banned"
      Iffy::User::BanService.new(id).perform
    when "user.suspended"
      Iffy::User::SuspendService.new(id).perform
    when "user.compliant"
      Iffy::User::MarkCompliantService.new(id).perform unless user_suspended_by_admin?(id)
    when "record.flagged"
      if entity == "Product" && !user_protected?(user)
        Iffy::Product::FlagService.new(id).perform
      elsif entity == "Post" && !user_protected?(user)
        Iffy::Post::FlagService.new(id).perform
      end
    when "record.compliant"
      if entity == "Product"
        Iffy::Product::MarkCompliantService.new(id).perform
      elsif entity == "Post"
        Iffy::Post::MarkCompliantService.new(id).perform
      end
    end
  end

  private
    def user_protected?(user)
      user&.dig("protected") == true
    end

    def user_suspended_by_admin?(user_external_id)
      user = User.find_by_external_id(user_external_id)
      return false unless user

      user.suspended_by_admin?
    end
end
