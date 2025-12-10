# frozen_string_literal: true

class Admin::PostPresenter
  attr_reader :post

  def initialize(post:)
    @post = post
  end

  def props
    {
      external_id: post.external_id,
      name: post.name,
      created_at: post.created_at
    }
  end
end
