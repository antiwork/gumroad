# frozen_string_literal: true

# Staff override for a post email blast waiting for the seller's daily large-email slot.
class Api::Internal::Admin::PostEmailBlastsController < Api::Internal::Admin::BaseController
  # Sending around a limit needs an attributable actor, not the shared legacy token.
  before_action :require_per_actor_token!

  def send_now
    reason = params[:reason].to_s.strip
    return render json: { success: false, message: "reason is required" }, status: :bad_request if reason.blank?

    blast = PostEmailBlast.find_by(id: params[:id])
    return render json: { success: false, message: "Blast not found" }, status: :not_found if blast.nil?

    seller = blast.seller
    record_admin_write(action: "post_email_blasts.send_now", target: blast) do
      result = PostBlastQuotaOverride.new(blast:).perform!
      comment = seller.comments.create!(
        content: "Sent post email blast #{blast.id} now, skipping the daily limit for large emails. Reason: #{reason}",
        comment_type: Comment::COMMENT_TYPE_NOTE,
        author_id: current_admin_actor_id
      )
      render json: {
        success: true,
        blast_id: blast.id,
        user_id: seller.external_id,
        removed_scheduled_copies: result[:removed_scheduled_copies],
        comment_id: comment.id
      }
    rescue PostBlastQuotaOverride::NotOverridable => e
      render json: { success: false, message: "Cannot send now: #{e.message}" }, status: :conflict
    end
  end
end
