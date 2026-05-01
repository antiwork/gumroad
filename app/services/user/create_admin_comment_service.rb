# frozen_string_literal: true

class User::CreateAdminCommentService
  class IdempotencyConflictError < StandardError; end

  def initialize(user:, content:, idempotency_key:, author_id: GUMROAD_ADMIN_ID)
    @user = user
    @content = content
    @idempotency_key = idempotency_key
    @author_id = author_id
  end

  def perform
    normalized_content = Comment.normalize_content(@content)

    existing = @user.comments.find_by(idempotency_key: @idempotency_key)
    if existing
      raise IdempotencyConflictError if existing.content != normalized_content
      return existing
    end

    comment = @user.comments.new(
      content: @content,
      comment_type: Comment::COMMENT_TYPE_NOTE,
      author_id: @author_id,
      idempotency_key: @idempotency_key
    )
    comment.save
    comment
  rescue ActiveRecord::RecordNotUnique
    existing = @user.comments.find_by!(idempotency_key: @idempotency_key)
    raise IdempotencyConflictError if existing.content != normalized_content
    existing
  end
end
