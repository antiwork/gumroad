# frozen_string_literal: true

class Admin::Users::Products::TosViolationFlagsController < Admin::Users::Products::BaseController
  def index
    if @user.flagged_for_tos_violation?
      render json: {
        tos_violation_flags: @product.comments.with_type_flagged.as_json(
          only: %i[id content]
        )
      }
    else
      render json: { tos_violation_flags: [] }
    end
  end

  def create
    suspend_tos_reason = suspend_tos_params[:reason]

    if @user.nil? || suspend_tos_reason.blank?
      render json: { success: false, error_message: "Invalid request" }, status: :bad_request
    elsif !@user.can_flag_for_tos_violation?
      render json: { success: false, error_message: "Cannot flag for TOS violation" }, status: :bad_request
    else
      ActiveRecord::Base.transaction do
        @user.update!(tos_violation_reason: suspend_tos_reason)
        comment_content = "Flagged for a policy violation on #{Time.current.to_fs(:formatted_date_full_month)} for a product named '#{@product.name}' (#{suspend_tos_reason})"
        @user.flag_for_tos_violation!(author_id: current_user.id, product_id: @product.id, content: comment_content)
        @product.public_send(@product.is_tiered_membership? ? :unpublish! : :delete!)
      end

      render json: { success: true }
    end
  end

  private
    def suspend_tos_params
      params.require(:suspend_tos).permit(:reason)
    end
end
