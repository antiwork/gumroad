# frozen_string_literal: true

# Does not inherit from ApplicationPolicy as this policy is used in a context where user is not authenticated,
# like CommentsController
# This is an exception from all other policies that are used within an authenticated area (where user and seller
# are set)
#
# Associated with Posts section
#
class CommentContextPolicy
  attr_reader :context, :user, :seller, :record

  def initialize(context, record)
    @context = context
    @user = context.user
    @seller = context.seller
    @record = record
  end

  def index?
    commentable = record.commentable
    purchase = record.purchase

    # Allow the seller of the post, and appropriate roles for the seller
    return true if user && commentable.respond_to?(:seller_id) && commentable.seller_id == seller.id && (user.role_admin_for?(seller) || user.role_marketing_for?(seller))

    # Allow the customer having valid 'purchase_id'
    return true if purchase && commentable.respond_to?(:eligible_purchase?) && commentable.eligible_purchase?(purchase)

    # Allow the user if the post is visible to them
    return true if commentable.respond_to?(:seller_id) && commentable.seller.visible_posts_for(pundit_user: context, shown_on_profile: false).include?(commentable)

    false
  end

  def create?
    commentable = record.comment.commentable
    purchase = record.purchase

    # Allow the seller of the post, and appropriate roles for the seller
    return true if user && commentable.respond_to?(:seller_id) && commentable.seller_id == seller.id && (user.role_admin_for?(seller) || user.role_marketing_for?(seller))

    # Allow the customer having valid 'purchase_id'
    return true if purchase && commentable.respond_to?(:eligible_purchase?) && commentable.eligible_purchase?(purchase)

    # Allow the user if the post is visible to them
    return true if commentable.respond_to?(:seller_id) && commentable.seller.visible_posts_for(pundit_user: context, shown_on_profile: false).include?(commentable)

    false
  end

  def update?
    comment = record.comment
    purchase = record.purchase

    # Allow the purchaser of the post's belonging product
    return true if purchase.present? && purchase.id == comment.purchase_id

    # Allow the author of the comment
    return true if user && comment.author_id.present? && comment.author_id == user.id

    false
  end

  def destroy?
    comment = record.comment
    purchase = record.purchase

    # Allow the seller of the post, and appropriate roles for the seller
    return true if user && comment.commentable.respond_to?(:seller_id) && comment.commentable.seller_id == seller.id && (user.role_admin_for?(seller) || user.role_marketing_for?(seller))

    # Allow the purchaser of the post's belonging product
    return true if purchase.present? && purchase.id == comment.purchase_id

    # Allow the author of the comment
    return true if user && comment.author_id.present? && comment.author_id == user.id

    false
  end
end
