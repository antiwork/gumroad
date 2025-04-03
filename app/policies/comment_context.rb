# frozen_string_literal: true

class CommentContext
  attr_reader :comment, :commentable, :purchase

  def initialize(comment:, commentable:, purchase:)
    @comment = comment
    @commentable = commentable
    @purchase = purchase
  end
end
