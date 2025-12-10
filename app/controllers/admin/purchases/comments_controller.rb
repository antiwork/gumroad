# frozen_string_literal: true

class Admin::Purchases::CommentsController < Admin::BaseController
  include Admin::Commentable

  private
    def commentable
      Purchase.find_by_external_id!(params[:purchase_external_id])
    end
end
