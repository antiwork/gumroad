# frozen_string_literal: true

# Admin API surface for stranded-buyer recovery, so gumroad-cli can scan and recover by external
# id instead of a human reconstructing the rules in a console (gumroad-private#1640).
class Api::Internal::Admin::StrandedBuyersController < Api::Internal::Admin::BaseController
  MAX_SCAN_RESULTS = 100

  def scan
    result = Risk::StrandedBuyerScanService.call

    render json: {
      success: true,
      candidates: result[:stranded].first(scan_limit).map { serialize_candidate(_1) },
      count: [result[:stranded].size, scan_limit].min,
      total: result[:stranded].size,
      truncated: result[:truncated],
    }
  end

  def recover
    email = params[:email].to_s.strip.presence
    user_external_id = params[:user_id].to_s.strip.presence
    if email.blank? && user_external_id.blank?
      return render json: { success: false, message: "email or user_id is required" }, status: :bad_request
    end

    # Defaults to a dry run: clearing has to be asked for, same as every prior sweep.
    dry_run = params.key?(:dry_run) ? ActiveModel::Type::Boolean.new.cast(params[:dry_run]) : true

    record_admin_write(action: "stranded_buyers.recover") do
      result = Risk::StrandedBuyerRecoveryService.call(email:, user_external_id:, dry_run:)
      render json: { success: true }.merge(result.to_h)
    rescue Risk::StrandedBuyerRecoveryService::UnsafeClearError,
           Risk::StrandedBuyerRecoveryService::VerificationFailedError => e
      render json: { success: false, message: e.message }, status: :unprocessable_entity
    end
  end

  private
    def scan_limit
      requested = params[:limit].to_i
      return MAX_SCAN_RESULTS if requested <= 0

      [requested, MAX_SCAN_RESULTS].min
    end

    def serialize_candidate(entry)
      {
        email: entry[:email],
        user_id: entry[:purchaser_external_id],
        settled_purchases: entry[:settled_purchases],
        blocked_at: entry[:blocked_at].as_json,
        block_type: entry[:block_type],
        failed_at: entry[:failed_at].as_json,
        attempts: entry[:attempts],
      }
    end
end
