# frozen_string_literal: true

class Api::Internal::Installments::NonOpenerResendsController < Api::Internal::BaseController
  RESEND_THROTTLE = 24.hours
  MAX_RESENDS = 3
  IN_FLIGHT_GRACE = 1.hour
  # Computing the non-opener count means scanning every emailed recipient, every open
  # event, and the seller's full audience. For very large sends (hundreds of thousands
  # of recipients) that cannot finish inside a web request, so the whole preview shares
  # one total time budget and the endpoint degrades to "count unavailable" instead of
  # erroring the whole page. The budget is enforced as a shrinking per-statement cap:
  # each query runs under whatever is LEFT of the budget (not a fresh 10 seconds), so
  # several individually-fast statements can't add up past the budget and hit the HTTP
  # request deadline instead.
  COUNT_PREVIEW_TOTAL_BUDGET_SECONDS = 10

  before_action :authenticate_user!
  before_action :set_installment
  after_action :verify_authorized

  def show
    authorize @installment, :resend_to_non_openers?

    count = nil
    audience_filtered_out = false
    begin
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + COUNT_PREVIEW_TOTAL_BUDGET_SECONDS

      unopened_emails = within_preview_budget(deadline) { @installment.unopened_recipient_emails }
      if unopened_emails.empty?
        count = 0
      else
        # Reuse the emails computed above rather than letting the model recompute them —
        # they are the expensive part, and running them twice would double the time spent.
        count = within_preview_budget(deadline) do
          @installment.resendable_to_non_openers_emails(candidates: unopened_emails).size
        end
        audience_filtered_out = count.zero?
      end
    rescue WithMaxExecutionTime::QueryTimeoutError
      # The audience is too large to count within the budget. A null count tells the
      # UI to offer the resend without a recipient number — the actual send happens in
      # a background job, so a missing preview count doesn't block anything.
      count = nil
      audience_filtered_out = false
    end

    render json: { count:, recently_resent: recently_resent?, audience_filtered_out: }
  end

  def create
    authorize @installment, :resend_to_non_openers?

    blast = nil
    error_response = nil
    @installment.with_lock do
      if resend_limit_reached?
        error_response = [{ success: false, error: "You can resend to non-openers up to #{MAX_RESENDS} times per email." }, :unprocessable_entity]
        next
      end

      if recently_resent?
        error_response = [{ success: false, error: "You can only resend to non-openers once every 24 hours." }, :unprocessable_entity]
        next
      end

      blast = PostEmailBlast.create!(
        post: @installment,
        requested_at: Time.current,
        recipient_filter: PostEmailBlast::RECIPIENT_FILTER_UNOPENED
      )
    end

    if error_response
      json, status = error_response
      return render json:, status:
    end

    # Recipient eligibility is intentionally NOT computed here: for large audiences
    # that computation takes minutes and used to time the request out before the blast
    # was even created. The job resolves the recipient list itself, and a blast that
    # turns out to have zero eligible recipients simply completes with delivery_count 0
    # (which doesn't count toward the resend cap or the 24h throttle).
    SendPostBlastEmailsJob.perform_async(blast.id)
    render json: { success: true }
  end

  private
    # Runs the block under a MySQL statement cap equal to the time REMAINING until
    # `deadline`, so consecutive queries share one overall budget instead of each
    # getting the full amount. A budget that is already spent raises the same
    # QueryTimeoutError a slow statement would, keeping one degrade path.
    def within_preview_budget(deadline, &block)
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise WithMaxExecutionTime::QueryTimeoutError, "count preview budget exhausted" if remaining <= 0

      WithMaxExecutionTime.timeout_queries(seconds: remaining, &block)
    end

    def set_installment
      @installment = current_seller.installments.alive.find_by_external_id(params[:id])
      (skip_authorization and e404_json) unless @installment&.resendable_to_non_openers?
    end

    def recently_resent?
      scope = @installment.blasts.to_non_openers
      return true if scope.where(completed_at: nil).where(requested_at: IN_FLIGHT_GRACE.ago..).exists?

      scope.where(completed_at: RESEND_THROTTLE.ago..).where(delivery_count: 1..).exists?
    end

    def resend_limit_reached?
      @installment.blasts.to_non_openers.where.not(completed_at: nil).where(delivery_count: 1..).count >= MAX_RESENDS
    end
end
