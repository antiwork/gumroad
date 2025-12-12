# frozen_string_literal: true

class Admin::Purchases::CommentsController < Admin::BaseController
  include Admin::Commentable

  private
    def commentable
      Purchase.find(params[:purchase_id])
    end
end
