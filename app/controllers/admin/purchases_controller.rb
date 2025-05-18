# frozen_string_literal: true

class Admin::PurchasesController < Admin::BaseController
  include RiskState

  before_action :fetch_purchase, only: %i[refund refund_for_fraud show unblock_buyer]

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

  def show
    e404 if @purchase.nil?
    @product = @purchase.link
    @title = "Purchase #{@purchase.id}"
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

  private
    def fetch_purchase
      @purchase = Purchase.find_by(id: params[:id]) if params[:id].to_i.to_s == params[:id]
      @purchase ||= Purchase.find_by_external_id(params[:id])
      @purchase ||= Purchase.find_by_external_id_numeric(params[:id].to_i)
      @purchase ||= Purchase.find_by_stripe_transaction_id(params[:id])
    end
end
