# frozen_string_literal: true

class CommentsController < ApplicationController
  before_action :set_post, only: %i[index create update destroy]
  before_action :set_comment, only: %i[update destroy]
  before_action :set_purchase, only: %i[index create update destroy]
  before_action :build_post_comment, only: %i[create]
  after_action :verify_authorized

  def index
    comment_context = CommentContext.new(
      comment: nil,
      commentable: @post,
      purchase: @purchase
    )
    authorize comment_context

    render json: PaginatedCommentsPresenter.new(
      pundit_user:,
      commentable: @post,
      purchase: @purchase,
      options: { page: params[:page] }
    ).result
  end

  def create
    comment_context = CommentContext.new(
      comment: @comment,
      commentable: nil,
      purchase: @purchase
    )
    authorize comment_context

    if @comment.save
      render json: { success: true, comment: comment_json }
    else
      render json: { success: false, error: @comment.errors.full_messages.first }, status: :unprocessable_entity
    end
  end

  def update
    comment_context = CommentContext.new(
      comment: @comment,
      commentable: nil,
      purchase: @purchase
    )
    authorize comment_context

    if @comment.update(permitted_update_params)
      render json: { success: true, comment: comment_json }
    else
      render json: { success: false, error: @comment.errors.full_messages.first }, status: :unprocessable_entity
    end
  end

  def destroy
    comment_context = CommentContext.new(
      comment: @comment,
      commentable: nil,
      purchase: @purchase
    )
    authorize comment_context

    deleted_comments = @comment.mark_subtree_deleted!
    render json: { success: true, deleted_comment_ids: deleted_comments.map(&:external_id) }
  end

  private
    def build_post_comment
      comment_author = logged_in_user || @purchase&.purchaser
      parent_comment = permitted_create_params[:parent_id].presence && Comment.find_by_external_id(permitted_create_params[:parent_id])
      @comment = @post.comments.new(permitted_create_params.except(:parent_id))
      @comment.parent_id = parent_comment&.id
      @comment.author_id = comment_author&.id
      @comment.author_name = comment_author&.display_name || @purchase&.full_name || @purchase&.email
      # When 'author_id' is not available, we can fallback to associated
      # `purchase` to recognize the comment author
      @comment.purchase = @purchase
      @comment.comment_type = Comment::COMMENT_TYPE_USER_SUBMITTED
    end

    def comment_json
      CommentPresenter.new(
        pundit_user:,
        comment: @comment,
        purchase: @purchase
      ).comment_component_props
    end

    def set_post
      @post = Installment.published.find_by_external_id(params[:post_id])

      e404_json if @post.blank?
    end

    def set_comment
      @comment = @post.comments.find_by_external_id(params[:id])

      e404_json if @comment.blank?
    end

    def set_purchase
      # Post author doesn't need a purchase
      return if current_seller && current_seller.id == @post.seller_id

      if params[:purchase_id]
        @purchase = Purchase.find_by_external_id(params[:purchase_id])
      elsif logged_in_user
        @purchase = Purchase.where(purchaser_id: logged_in_user.id, link_id: @post.link&.id)
                            .all_success_states
                            .not_chargedback_or_chargedback_reversed
                            .not_fully_refunded
                            .first
      end

      if @purchase.present? && @purchase.link.is_recurring_billing
        subscription = Subscription.find(@purchase.subscription_id)
        @purchase = subscription.original_purchase
      end
    end

    def permitted_create_params
      params.require(:comment).permit(:content, :parent_id)
    end

    def permitted_update_params
      params.require(:comment).permit(:content)
    end
end
