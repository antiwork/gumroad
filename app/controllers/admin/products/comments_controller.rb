# frozen_string_literal: true

class Admin::Products::CommentsController < Admin::Products::BaseController
  include Admin::Commentable

  private
    def commentable
      @product
    end
end
