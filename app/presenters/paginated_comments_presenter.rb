# frozen_string_literal: true

require "pagy/extras/standalone"

class PaginatedCommentsPresenter
  include Pagy::Backend

  COMMENTS_PER_PAGE = 20

  attr_reader :commentable, :pundit_user, :purchase, :options, :page

  def initialize(pundit_user:, commentable:, purchase:, options: {})
    @pundit_user = pundit_user
    @commentable = commentable
    @purchase = purchase
    @options = options
    @page = [options[:page].to_i, 1].max
  end

  def result
    root_comments = commentable.comments.alive.order(:created_at).roots
    pagination, paginated_root_comments = pagy(root_comments, limit: COMMENTS_PER_PAGE, url: "", page:)
    comments = comments_with_descendants(paginated_root_comments).includes(:commentable, author: { avatar_attachment: :blob }).alive
    comments_json = comments.map do |comment|
      CommentPresenter.new(pundit_user:, comment:, purchase:).comment_component_props
    end

    {
      comments: comments_json,
      count: commentable.comments.alive.count,
      pagination: PagyPresenter.new(pagination).metadata
    }
  end

  private
    def comments_with_descendants(comments)
      comments.inject(Comment.none) do |scope, parent|
        scope.or parent.subtree.order(:created_at).to_depth(Comment::MAX_ALLOWED_DEPTH)
      end
    end
end
