# frozen_string_literal: true

class Admin::CommentsController < Admin::BaseController
  skip_before_action :require_admin!, if: :request_from_iffy?

  def create
    Comment.create!(comment_params)

    render json: { success: true }
  end

  private
    def comment_params
      permitted_params = params.require(:comment).permit(:commentable_id, :commentable_type, :author_id,
                                                         :author_name, :content, :comment_type)
      permitted_params[:author_id] = current_user.id unless request_from_iffy?
      permitted_params
    end
end
