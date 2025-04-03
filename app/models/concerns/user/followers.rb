# frozen_string_literal: true

module User::Followers
  extend ActiveSupport::Concern

  included do
    has_many :followers, foreign_key: "followed_id"
  end

  def follower_by_email(email)
    Follower.active.find_by(followed_id: id, email:)
  end

  def followed_by?(email)
    follower_by_email(email).present?
  end

  def following
    Follower.includes(:user)
            .active
            .where(email: form_email)
            .where.not(followed_id: id)
            .map { |follower| { external_id: follower.external_id, creator: follower.user } }
  end

  def add_follower(email, options = {})
    follower_attributes = options.dup
    logged_in_user = follower_attributes.delete(:logged_in_user)

    Follower::CreateService.perform(
      followed_user: self,
      follower_email: email,
      follower_attributes:,
      logged_in_user:
    )
  end
end
