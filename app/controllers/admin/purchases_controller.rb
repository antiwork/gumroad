# frozen_string_literal: true

class Admin::PurchasesController < Admin::BaseController
  before_action :fetch_purchase, only: %i[cancel_subscription refund refund_for_fraud refund_taxes_only resend_receipt
                                          show sync_status_with_charge_processor block_buyer unblock_buyer undelete update_giftee_email]

  def cancel_subscription
    if @purchase.subscription
      @purchase.subscription.cancel!(by_seller: params[:by_seller] == "true", by_admin: true)
      render json: { success: true }
    else
      render json: { success: false }
    end
  end

  def refund
    if @purchase.refund_and_save!(current_user.id)
      render json: { success: true }
    else
      render json: { success: false }
    end
  end

  def refund_for_fraud
    if @purchase.refund_for_fraud_and_block_buyer!(current_user.id)
      render json: { success: true }
    else
      render json: { success: false }
    end
  end

  def refund_taxes_only
    e404 if @purchase.nil?

    if @purchase.refund_gumroad_taxes!(refunding_user_id: current_user.id, note: params[:note], business_vat_id: params[:business_vat_id])
      render json: { success: true }
    else
      render json: { success: false, message: @purchase.errors.full_messages.presence&.to_sentence || "No refundable taxes available" }
    end
  end

  def resend_receipt
    if @purchase
      if params[:resend_receipt][:email_address].present?
        @purchase.email = params[:resend_receipt][:email_address]
        @purchase.save!

        if @purchase.subscription.present? && !@purchase.is_original_subscription_purchase?
          @purchase.original_purchase.update!(email: params[:resend_receipt][:email_address])
        end

        user = User.alive.find_by(email: @purchase.email)
        @purchase.attach_to_user_and_card(user, nil, nil) if user
      end

      @purchase.resend_receipt
      render json: { success: true }
    else
      e404_json
    end
  rescue ActiveRecord::RecordInvalid => e
    render json: { message: e.message }, status: :unprocessable_content
  end

  def show
    e404 if @purchase.nil?
    @product = @purchase.link
    set_meta_tag(title: "Purchase #{@purchase.external_id}")
    purchase = Admin::PurchasePresenter.new(@purchase).props
    render(
      inertia: "Admin/Purchases/Show",
      props: {
        purchase:,
        product: Admin::ProductPresenter::Card.new(product: @product, pundit_user:).props,
        user: Admin::UserPresenter::Card.new(user: @product.user, pundit_user:).props
      },
    )
  end

  def sync_status_with_charge_processor
    @purchase.sync_status_with_charge_processor(mark_as_failed: true)
  end

  def block_buyer
    @purchase.block_buyer!(blocking_user_id: current_user.id)
    render json: { success: true }
  rescue => e
    render json: { success: false, message: e.message }
  end

  def unblock_buyer
    if @purchase.buyer_blocked?
      @purchase.unblock_buyer!

      comment_content = "Buyer unblocked by Admin (#{current_user.email})"
      @purchase.comments.create!(content: comment_content, comment_type: "note", author_id: current_user.id)

      if @purchase.purchaser.present?
        @purchase.purchaser.comments.create!(content: comment_content,
                                             comment_type: "note",
                                             author: current_user,
                                             purchase: @purchase)
      end
    end

    render json: { success: true }
  rescue => e
    render json: { success: false, message: e.message }
  end

  def undelete
    e404 if @purchase.nil?

    begin
      if @purchase.is_deleted_by_buyer?
        @purchase.update!(is_deleted_by_buyer: false)

        comment_content = "Purchase undeleted by Admin (#{current_user.email})"
        @purchase.comments.create!(content: comment_content, comment_type: "note", author_id: current_user.id)

        if @purchase.purchaser.present?
          @purchase.purchaser.comments.create!(content: comment_content,
                                               comment_type: "note",
                                               author: current_user,
                                               purchase: @purchase)
        end
      end

      render json: { success: true }
    rescue => e
      render json: { success: false, message: e.message }
    end
  end

  def update_giftee_email
    new_giftee_email = params[:giftee_email]

    if (gift = @purchase.gift_given).present? && new_giftee_email != gift.giftee_email
      giftee_purchase = Purchase.find_by(id: gift.giftee_purchase_id)
      if giftee_purchase.present?
        gift.update!(giftee_email: new_giftee_email)
        giftee_purchase.update!(email: new_giftee_email)

        giftee_purchase.resend_receipt
        redirect_to admin_purchase_path(@purchase.external_id)
      else
        render json: {
          success: false,
          message: "This gift is missing a giftee purchase. Please ask an engineer to generate one with script here: https://github.com/gumroad/web/issues/17248#issuecomment-784478299",
        }
      end
    end
  end

  private
    def fetch_purchase
      if !Purchase.external_id?(params[:external_id]) && purchase = Purchase.find_by(id: params[:external_id])
        return redirect_to admin_purchase_path(purchase.external_id)
      end

      @purchase = Purchase.find_by_external_id(params[:external_id])
      @purchase ||= Purchase.find_by_external_id_numeric(params[:external_id].to_i)
      @purchase ||= Purchase.find_by_stripe_transaction_id(params[:external_id])
    end
end
