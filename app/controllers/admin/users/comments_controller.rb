# frozen_string_literal: true

class Admin::Users::CommentsController < Admin::Users::BaseController
  include Admin::Commentable
  before_action :fetch_user

  private
    def commentable
      @user
    end
end
