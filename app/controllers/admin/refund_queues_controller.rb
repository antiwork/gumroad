# frozen_string_literal: true

class Admin::RefundQueuesController < Admin::BaseController
  include Admin::ListPaginatedUsers

  def show
    set_meta_tag(title: "Refund queue")
    @users = User.refund_queue

    list_paginated_users users: @users,
                         template: "Admin/RefundQueues/Show"
  end
end
