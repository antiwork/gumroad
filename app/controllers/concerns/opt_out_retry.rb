# frozen_string_literal: true

# An opt-out that waited too long for a follow a post handoff is holding (Follower.with_opt_out_lock_wait) left that
# follow unchanged and can simply be repeated. Programs read Retry-After; a person who followed an unsubscribe link
# gets a page that says so, with a link that repeats the same GET.
module OptOutRetry
  extend ActiveSupport::Concern

  private
    def retry_opt_out_later(retry_page: false)
      response.headers["Retry-After"] = Follower::OPT_OUT_RETRY_AFTER_SECONDS.to_s
      if retry_page && request.get? && request.format.html?
        @body_id = "app"
        @hide_layouts = true
        render "opt_outs/retry_later", layout: "application", status: :service_unavailable
      else
        head :service_unavailable
      end
    end
end
