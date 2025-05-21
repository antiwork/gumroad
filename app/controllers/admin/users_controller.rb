# frozen_string_literal: true

class Admin::UsersController < Admin::BaseController
  include Pagy::Backend
  include MassTransferPurchases

  before_action :fetch_user, except: %i[refund_queue block_ip_address]
  before_action :require_user_has_payout_privileges!, only: %i[
    create_stripe_managed_account
  ]

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
    @users = User.refund_queue
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
