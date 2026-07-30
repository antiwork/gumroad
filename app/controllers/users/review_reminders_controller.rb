# frozen_string_literal: true

class Users::ReviewRemindersController < ApplicationController
  layout "inertia"

  # The token-carrying actions are the ones linked from review reminder emails, so they
  # cannot require a session. Recipients of a review reminder are frequently free-download
  # buyers with no usable login, which is what made the login-gated link a dead end.
  TOKEN_SCOPE = "unsubscribe_review_reminders"
  PUBLIC_ACTIONS = %i[subscribe_by_token unsubscribe_by_token].freeze

  before_action :authenticate_user!, except: PUBLIC_ACTIONS
  before_action :set_user_from_token, only: PUBLIC_ACTIONS

  def subscribe
    logged_in_user.update!(opted_out_of_review_reminders: false)
    render inertia: "Users/ReviewReminders/Subscribe"
  end

  def unsubscribe
    logged_in_user.update!(opted_out_of_review_reminders: true)
    render inertia: "Users/ReviewReminders/Unsubscribe"
  end

  def subscribe_by_token
    @user.update!(opted_out_of_review_reminders: false)
    render inertia: "Users/ReviewReminders/Subscribe"
  end

  def unsubscribe_by_token
    @user.update!(opted_out_of_review_reminders: true)

    # Hand the page a tokenized resubscribe URL: someone who got here from an email has no
    # session, so the logged-in resubscribe path would send them to a login wall.
    render inertia: "Users/ReviewReminders/Unsubscribe", props: {
      subscribe_url: user_subscribe_review_reminders_by_token_path(@user.secure_external_id(scope: TOKEN_SCOPE))
    }
  end

  private
    def set_user_from_token
      @user = User.find_by_secure_external_id(params[:id], scope: TOKEN_SCOPE)
      redirect_to root_path if @user.nil?
    end
end
