# frozen_string_literal: true

# Seller notice for a Stripe court-order ("restraint") notice on their connected account
# (gumroad-private#3598). The mail-side automation calls this until it answers already_sent.
class Api::Internal::Admin::StripeRestraintNoticesController < Api::Internal::Admin::BaseController
  # Emailing a seller about a court order needs an attributable actor, not the shared legacy token.
  before_action :require_per_actor_token!

  def create
    notice = StripeRestraintNoticeService.new(
      stripe_account_id: params[:stripe_account_id],
      firm_name: params[:firm_name],
      firm_email: params[:firm_email],
      notice_key: params[:notice_key],
      author_id: current_admin_actor_id
    )
    user = notice.user
    return render_preview(notice.preview) unless send_requested?

    record_admin_write(action: "stripe_restraint_notices.create", target: user) do
      render json: notice_payload(notice.perform)
    rescue StripeRestraintNoticeService::Error => e
      render_notice_error(e)
    end
  rescue StripeRestraintNoticeService::Error => e
    render_notice_error(e)
  end

  private
    # Anything but an explicit false is a dry run, so a missing or garbled flag never emails a seller.
    def send_requested?
      params.key?(:dry_run) && ActiveModel::Type::Boolean.new.cast(params[:dry_run]) == false
    end

    # A dry run writes nothing, so it skips the token's usage stamp too.
    def record_admin_token_use?
      send_requested?
    end

    def render_preview(result)
      mail = result.mail
      render json: notice_payload(result).merge(
        email: {
          from: mail[:from].to_s,
          reply_to: mail.reply_to,
          to: mail.to,
          subject: mail.subject,
          html_body: (mail.html_part || mail).body.decoded
        }
      )
    end

    # delivery_status "accepted" means the mail service took the email, not that it reached the inbox.
    def notice_payload(result)
      comment = result.comment
      accepted = result.accepted
      {
        success: true,
        status: result.status,
        already_sent: accepted.present?,
        delivery_status: comment && (accepted ? "accepted" : "pending"),
        accepted_at: accepted&.created_at&.iso8601,
        user: { user_id: result.user.external_id, email: result.user.email, name: result.user.name },
        comment_id: comment&.external_id,
        comment: comment && { content: comment.content, created_at: comment.created_at.iso8601 }
      }
    end

    def render_notice_error(error)
      render json: { success: false, message: error.message }, status: error.status
    end
end
