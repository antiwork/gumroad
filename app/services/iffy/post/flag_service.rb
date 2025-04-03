# frozen_string_literal: true

class Iffy::Post::FlagService
  attr_reader :post

  def initialize(post_id)
    @post = Installment.find_by_external_id!(post_id)
  end

  def perform
    post.unpublish!(is_unpublished_by_admin: true)
  end
end
