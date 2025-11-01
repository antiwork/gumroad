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

    render inertia: "Admin/Users/Show", props: {
      user: serialize_user(@user),
      products: @products.map { |product| serialize_product(product) },
      pagy: serialize_pagy(@pagy),
      is_affiliate_user: false,
      user_memberships: serialize_user_memberships(@user),
      active_bank_account: serialize_bank_account(@user.active_bank_account),
      merchant_accounts: @user.merchant_accounts.map { |ma| serialize_merchant_account(ma) },
      compliance_info: serialize_compliance_info(@user.alive_user_compliance_info),
      last_posts: serialize_posts(@user.last_5_created_posts),
      comments: serialize_comments(@user.comments.includes(:author).references(:author).order(created_at: :desc)),
      email_versions: serialize_email_versions(@user),
      stripe_account_exists: @user.stripe_account.present?,
      manual_payout_eligible: manual_payout_eligible?(@user),
      stripe_payable_data: stripe_payable_data(@user),
      paypal_payable_data: paypal_payable_data(@user),
      manual_payout_period_end_date: User::PayoutSchedule.manual_payout_end_date&.iso8601,
      currency: @user.stripe_account&.currency
    }
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

    # Serialization methods for Inertia
    def serialize_user(user)
      {
        id: user.id,
        external_id: user.external_id,
        name: user.name,
        username: user.username,
        email: user.email,
        form_email: user.form_email,
        support_email: user.support_email,
        avatar_url: user.avatar_url,
        bio: user.bio,
        created_at: user.created_at.iso8601,
        updated_at: user.updated_at.iso8601,
        deleted_at: user.deleted_at&.iso8601,
        verified: user.verified,
        user_risk_state: user.user_risk_state,
        all_adult_products: user.all_adult_products,
        custom_fee_per_thousand: user.custom_fee_per_thousand,
        unpaid_balance_cents: user.unpaid_balance_cents,
        disable_paypal_sales: user.disable_paypal_sales,
        subdomain_with_protocol: user.subdomain_with_protocol,
        tos_violation_reason: user.tos_violation_reason,
        can_impersonate: policy([:admin, :impersonators, user]).create?,
        has_payments: user.payments.any?,
        payment_address: user.payment_address,
        payouts_paused_by_source: user.payouts_paused_by_source,
        payouts_paused_for_reason: user.payouts_paused_for_reason
      }
    end

    def serialize_product(product)
      {
        id: product.id,
        unique_permalink: product.unique_permalink,
        name: product.name,
        price_formatted: product.price_formatted,
        preview_url: product.preview_url ? helpers.cdn_url_for(product.preview_url) : nil,
        long_url: product.long_url,
        created_at: product.created_at.iso8601,
        alive: product.alive?,
        deleted_at: product.deleted_at&.iso8601,
        user_id: product.user_id
      }
    end

    def serialize_pagy(pagy)
      {
        page: pagy.page,
        pages: pagy.pages,
        count: pagy.count,
        prev: pagy.prev,
        next: pagy.next
      }
    end

    def serialize_user_memberships(user)
      memberships = user.user_memberships_not_deleted_and_ordered.reject(&:role_owner?)
      memberships.map do |membership|
        {
          id: membership.id,
          seller_id: membership.seller_id,
          seller_name: membership.seller.display_name(prefer_email_over_default_username: true),
          seller_avatar_url: membership.seller.avatar_url,
          role: membership.role,
          last_accessed_at: membership.last_accessed_at&.iso8601,
          created_at: membership.created_at.iso8601
        }
      end
    end

    def serialize_bank_account(bank_account)
      return nil unless bank_account

      {
        type: bank_account.type,
        account_holder_full_name: bank_account.account_holder_full_name,
        formatted_account: bank_account.formatted_account
      }
    end

    def serialize_merchant_account(merchant_account)
      {
        id: merchant_account.id,
        charge_processor_id: merchant_account.charge_processor_id,
        charge_processor_merchant_id: merchant_account.charge_processor_merchant_id,
        alive: merchant_account.alive?,
        charge_processor_alive: merchant_account.charge_processor_alive?
      }
    end

    def serialize_compliance_info(compliance_info)
      return nil unless compliance_info

      {
        is_business: compliance_info.is_business,
        first_name: compliance_info.first_name,
        last_name: compliance_info.last_name,
        street_address: compliance_info.street_address,
        city: compliance_info.city,
        state: compliance_info.state,
        state_code: compliance_info.state_code,
        zip_code: compliance_info.zip_code,
        country: compliance_info.country,
        country_code: compliance_info.country_code,
        individual_tax_id_provided: compliance_info.individual_tax_id.present?,
        business_name: compliance_info.business_name,
        business_street_address: compliance_info.business_street_address,
        business_city: compliance_info.business_city,
        business_state: compliance_info.business_state,
        business_zip_code: compliance_info.business_zip_code,
        business_country: compliance_info.business_country,
        business_type: compliance_info.business_type,
        business_tax_id_provided: compliance_info.business_tax_id.present?
      }
    end

    def serialize_posts(posts)
      posts.map do |post|
        {
          id: post.id,
          name: post.name,
          url: @user.suspended? ? nil : build_view_post_route(post: post),
          created_at: post.created_at.iso8601
        }
      end
    end

    def serialize_comments(comments)
      comments.map do |comment|
        {
          id: comment.id,
          content: comment.content,
          author_name: comment.author_name || comment.author&.name_or_username,
          comment_type: comment.comment_type,
          created_at: comment.created_at.iso8601
        }
      end
    end

    def serialize_email_versions(user)
      fields = %w[email payment_address]
      versions = []

      user.versions_for(*fields).each do |version|
        version.changes.sort.each do |field, values|
          versions << {
            field: field,
            old_value: values.first,
            new_value: values.last,
            created_at: version.created_at.iso8601
          }
        end
      end

      versions
    end

    def manual_payout_eligible?(user)
      last_payout = user.payments.last
      return false unless last_payout.nil? || %w[completed failed returned reversed cancelled].include?(last_payout.state)

      manual_payout_period_end_date = User::PayoutSchedule.manual_payout_end_date
      stripe_payable = Payouts.is_user_payable(user, manual_payout_period_end_date, processor_type: PayoutProcessorType::STRIPE, from_admin: true)
      paypal_payable = Payouts.is_user_payable(user, manual_payout_period_end_date, processor_type: PayoutProcessorType::PAYPAL, from_admin: true)

      stripe_payable || paypal_payable
    end

    def stripe_payable_data(user)
      manual_payout_period_end_date = User::PayoutSchedule.manual_payout_end_date
      return nil unless manual_payout_eligible?(user)
      return nil unless Payouts.is_user_payable(user, manual_payout_period_end_date, processor_type: PayoutProcessorType::STRIPE, from_admin: true)

      {
        unpaid_balance_held_by_gumroad: helpers.formatted_dollar_amount(user.unpaid_balance_cents_up_to_date_held_by_gumroad(manual_payout_period_end_date)),
        unpaid_balance_held_by_stripe: helpers.formatted_amount_in_currency(user.unpaid_balance_holding_cents_up_to_date_held_by_stripe(manual_payout_period_end_date), user.stripe_account&.currency)
      }
    end

    def paypal_payable_data(user)
      manual_payout_period_end_date = User::PayoutSchedule.manual_payout_end_date
      return nil unless manual_payout_eligible?(user)
      return nil unless Payouts.is_user_payable(user, manual_payout_period_end_date, processor_type: PayoutProcessorType::PAYPAL, from_admin: true)

      {
        should_payout_be_split: user.should_paypal_payout_be_split?,
        split_payment_by_cents: PaypalPayoutProcessor.split_payment_by_cents(user)
      }
    end
end
