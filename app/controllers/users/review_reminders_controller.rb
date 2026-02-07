# frozen_string_literal: true

class Users::ReviewRemindersController < ApplicationController
  layout "inertia"

  before_action :authenticate_user!

  def subscribe
    logged_in_user.update!(opted_out_of_review_reminders: false)
    render inertia: "Users/ReviewReminders/Subscribe"
  end

  def unsubscribe
    logged_in_user.update!(opted_out_of_review_reminders: true)
    render inertia: "Users/ReviewReminders/Unsubscribe"
  end
end
