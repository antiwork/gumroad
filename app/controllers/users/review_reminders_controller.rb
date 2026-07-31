# frozen_string_literal: true

class Users::ReviewRemindersController < ApplicationController
  layout "inertia"

  # Recipients of a review reminder are frequently free-download buyers with no usable
  # login, so the emailed links resolve the user from a token instead of a session.
  # ⚠️ This value is baked into every token already sitting in an inbox — renaming it
  # silently kills those links. spec pins the literal.
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
    set_review_reminder_opt_out(false)
    render inertia: "Users/ReviewReminders/Subscribe"
  end

  def unsubscribe_by_token
    set_review_reminder_opt_out(true)

    # The visitor has no session, so the resubscribe link has to carry a token too. Reuse
    # the one from the URL rather than minting a second: same scope, same capability.
    render inertia: "Users/ReviewReminders/Unsubscribe", props: {
      subscribe_url: user_subscribe_review_reminders_by_token_path(params[:id])
    }
  end

  private
    def set_user_from_token
      @user = User.find_by_secure_external_id(params[:id], scope: TOKEN_SCOPE)
      redirect_to root_path if @user.nil?
    end

    # These links land on exactly the dormant accounts least likely to satisfy current
    # User validations, and failing to honour an unsubscribe is worse than saving a row
    # that was already invalid. Mirrors Purchase#unsubscribe_buyer.
    def set_review_reminder_opt_out(opted_out)
      @user.update!(opted_out_of_review_reminders: opted_out)
    rescue ActiveRecord::RecordInvalid
      Rails.logger.info("[ReviewReminders] User #{@user.id} failed validation; opting out without validations.")
      @user.opted_out_of_review_reminders = opted_out
      @user.save(validate: false)
    end
end
