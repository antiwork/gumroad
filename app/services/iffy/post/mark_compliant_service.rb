# frozen_string_literal: true

class Iffy::Post::MarkCompliantService
  attr_reader :post

  def initialize(post_id)
    @post = Installment.find_by_external_id!(post_id)
  end

  def perform
    return unless !post.published? && post.is_unpublished_by_admin?
    post.is_unpublished_by_admin = false
    post.publish!
  end
end
