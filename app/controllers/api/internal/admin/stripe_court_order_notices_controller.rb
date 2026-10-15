# frozen_string_literal: true

# Seller notice for a Stripe court order on their connected account (gumroad-private#3598). Gumclaw
# verifies the Stripe email and calls this; the seller email and its dedup live here.
class Api::Internal::Admin::StripeCourtOrderNoticesController < Api::Internal::Admin::BaseController
  # Emailing a seller about a court order needs an attributable actor, not the shared legacy token.
  before_action :require_per_actor_token!

  def create
    notice = User::StripeCourtOrderNoticeService.new(
      stripe_account_id: params[:stripe_account_id],
      firm_name: params[:firm_name],
      firm_email: params[:firm_email],
      notice_key: params[:notice_key],
      author_id: current_admin_actor_id
    )
    user = notice.user
    return render_preview(notice.preview) unless send_requested?

    record_admin_write(action: "stripe_court_order_notices.create", target: user) do
      result = notice.perform
      render json: {
        success: true,
        status: result.status,
        user: serialize_seller(result.user),
        comment_id: result.comment.external_id,
        comment: { content: result.comment.content, created_at: result.comment.created_at.iso8601 }
      }
    rescue User::StripeCourtOrderNoticeService::Error => e
      render_notice_error(e)
    end
  rescue User::StripeCourtOrderNoticeService::Error => e
    render_notice_error(e)
  end

  private
    # Anything but an explicit false is a dry run, so a missing or garbled flag never emails a seller.
    def send_requested?
      params.key?(:dry_run) && ActiveModel::Type::Boolean.new.cast(params[:dry_run]) == false
    end

    def render_preview(result)
      mail = result.mail
      render json: {
        success: true,
        status: result.status,
        already_sent: result.comment.present?,
        user: serialize_seller(result.user),
        comment_id: result.comment&.external_id,
        email: {
          from: mail[:from].to_s,
          reply_to: mail.reply_to,
          to: mail.to,
          subject: mail.subject,
          html_body: (mail.html_part || mail).body.decoded
        }
      }
    end

    def serialize_seller(user)
      { user_id: user.external_id, email: user.email, name: user.name }
    end

    def render_notice_error(error)
      render json: { success: false, message: error.message }, status: error.status
    end
end
