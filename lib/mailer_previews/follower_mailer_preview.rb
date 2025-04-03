# frozen_string_literal: true

class FollowerMailerPreview < ActionMailer::Preview
  def confirm_follower
    if Follower.count.zero?
      follower_user = User.last
      User.first&.add_follower(
        follower_user&.email,
        follower_user_id: follower_user&.id,
        source: Follower::From::FOLLOW_PAGE,
        logged_in_user: follower_user
      )
    end
    follower = Follower.last
    FollowerMailer.confirm_follower(follower&.followed_id, follower&.id)
  end
end
