# frozen_string_literal: true

class Admin::UsersController < Admin::BaseController
  include Pagy::Backend
  include MassTransferPurchases

  skip_before_action :require_admin!, if: :request_from_iffy?, only: %i[suspend_for_fraud_from_iffy mark_compliant_from_iffy flag_for_explicit_nsfw_tos_violation_from_iffy]

  before_action :fetch_user, except: %i[refund_queue block_ip_address]

  helper Pagy::UrlHelpers

  PRODUCTS_ORDER = "ISNULL(COALESCE(purchase_disabled_at, banned_at, links.deleted_at)) DESC, created_at DESC"
  PRODUCTS_PER_PAGE = 10

  def show
    @title = "#{@user.display_name} on Gumroad"
    @pagy, @products = pagy(@user.links.order(Arel.sql(PRODUCTS_ORDER)), limit: PRODUCTS_PER_PAGE)
    respond_to do |format|
      format.html
      format.json { render json: @user }
    end
  end

  def stats
    render partial: "stats", locals: { user: @user }
  end

  def refund_balance
    RefundUnpaidPurchasesWorker.perform_async(@user.id, current_user.id)
    render json: { success: true }
  end

  def verify
    @user.verified = !@user.verified
    @user.save!
    render json: { success: true }
  rescue => e
    render json: { success: false, message: e.message }
  end

  def refund_queue
    @title = "Refund queue"
    @users = User.refund_queue.with_attached_avatar.includes(:admin_manageable_user_memberships, :links, :purchases)

    render inertia: "Admin/RefundQueues/Show",
           props: {
             users: @users.map { |user| user.as_json(admin: true, impersonatable: policy([:admin, :impersonators, user]).create?) }
           },
           legacy_template: "admin/users/refund_queue"
  end

  def enable
    @user.reactivate!
    render json: { success: true }
  end

  def update_email
    return if params[:update_email][:email_address].blank?

    @user.email = params[:update_email][:email_address]
    @user.save!
    render json: { success: true }
  end

  def reset_password
    @user.update!(password: SecureRandom.hex(24))

    render json: {
      success: true,
      message: "New password is #{@user.password}"
    }
  end

  def confirm_email
    @user.confirm
    @user.save!
    render json: { success: true }
  end

  def disable_paypal_sales
    @user.update!(disable_paypal_sales: true)
    render json: { success: true }
  end

  def create_stripe_managed_account
    merchant_account = StripeMerchantAccountManager.create_account(@user,
                                                                   passphrase: Rails.application.credentials.strongbox_general_password,
                                                                   from_admin: true)
    render json: {
      success: true,
      message: "Merchant Account created, ID: #{merchant_account.id} Stripe Account ID: #{merchant_account.charge_processor_merchant_id}",
      merchant_account_id: merchant_account.id,
      charge_processor_merchant_id: merchant_account.charge_processor_merchant_id
    }
  rescue MerchantRegistrationUserAlreadyHasAccountError
    render json: { success: false, message: "User already has a merchant account." }
  rescue MerchantRegistrationUserNotReadyError, Stripe::InvalidRequestError => e
    render json: { success: false, message: e.message }
  end

  def block_ip_address
    BlockedObject.block!(
      BLOCKED_OBJECT_TYPES[:ip_address],
      params[:ip_address],
      current_user.id,
      expires_in: BlockedObject::IP_ADDRESS_BLOCKING_DURATION_IN_MONTHS.months
    )
    render json: { success: true }
  end

  def mark_compliant
    @user.mark_compliant!(author_id: current_user.id)
    render json: { success: true }
  end

  def invalidate_active_sessions
    @user.invalidate_active_sessions!

    render json: { success: true, message: "User has been signed out from all active sessions." }
  end

  def mass_transfer_purchases
    transfer = transfer_purchases(user: @user, new_email: mass_transfer_purchases_params[:new_email])
    render json: { success: transfer[:success], message: transfer[:message] }, status: transfer[:status]
  end

  def mark_compliant_from_iffy
    @user.mark_compliant!(author_name: "iffy")
    render json: { success: true }
  rescue => e
    render json: { success: false, message: e.message }
  end

  def suspend_for_fraud
    unless @user.suspended?
      @user.suspend_for_fraud!(author_id: current_user.id)
      suspension_note = params.dig(:suspend_for_fraud, :suspension_note).presence
      if suspension_note
        @user.comments.create!(
          author_id: current_user.id,
          author_name: current_user.name,
          comment_type: Comment::COMMENT_TYPE_SUSPENSION_NOTE,
          content: suspension_note
        )
      end
    end
    render json: { success: true }
  rescue => e
    render json: { success: false, message: e.message }
  end

  def suspend_for_fraud_from_iffy
    @user.flag_for_fraud!(author_name: "iffy") unless @user.flagged_for_fraud? || @user.on_probation? || @user.suspended?
    @user.suspend_for_fraud!(author_name: "iffy") unless @user.suspended?
    render json: { success: true }
  rescue => e
    render json: { success: false, message: e.message }
  end

  def flag_for_explicit_nsfw_tos_violation_from_iffy
    @user.flag_for_explicit_nsfw_tos_violation!(author_name: "iffy") unless @user.flagged_for_explicit_nsfw?
    render json: { success: true }
  rescue => e
    render json: { success: false, message: e.message }
  end

  def flag_for_fraud
    if !@user.flagged_for_fraud? && !@user.suspended_for_fraud?
      @user.flag_for_fraud!(author_id: current_user.id)
      flag_note = params.dig(:flag_for_fraud, :flag_note).presence
      if flag_note
        @user.comments.create!(
          author_id: current_user.id,
          author_name: current_user.name,
          comment_type: Comment::COMMENT_TYPE_FLAG_NOTE,
          content: flag_note
        )
      end
    end
    render json: { success: true }
  rescue => e
    render json: { success: false, message: e.message }
  end

  def add_credit
    credit_params = params.require(:credit).permit(:credit_amount)
    credit_amount = credit_params[:credit_amount]

    if credit_amount.present?
      begin
        credit_amount_cents = (BigDecimal(credit_amount.to_s) * 100).round
        user_credit = Credit.create_for_credit!(
          user: @user,
          amount_cents: credit_amount_cents,
          crediting_user: current_user
        )
        user_credit.notify_user if credit_amount_cents > 0
        render json: { success: true, amount: credit_amount }
      rescue ArgumentError, Credit::Error => e
        render json: { success: false, message: e.message }
      end
    else
      render json: { success: false, message: "Credit amount is required" }
    end
  end

  def set_custom_fee
    custom_fee_per_thousand = params[:custom_fee_percent].present? ? (params[:custom_fee_percent].to_f * 10).round : nil
    @user.update!(custom_fee_per_thousand:)

    render json: { success: true }
  rescue => e
    render json: { success: false, message: e.message }
  end

  def toggle_adult_products
    @user.all_adult_products = !@user.all_adult_products
    @user.save!
    render json: { success: true }
  rescue => e
    render json: { success: false, message: e.message }
  end

  private
    def fetch_user
      if params[:id].include?("@")
        @user = User.find_by(email: params[:id])
      else
        @user = User.find_by(username: params[:id]) ||
                User.find_by(id: params[:id])
      end

      e404 unless @user
    end

    def mass_transfer_purchases_params
      params.require(:mass_transfer_purchases).permit(:new_email)
    end
end
