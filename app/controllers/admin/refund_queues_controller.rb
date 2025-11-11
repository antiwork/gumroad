# frozen_string_literal: true

class Admin::RefundQueuesController < Admin::BaseController
  include Admin::ListPaginatedUsers

  def show
    @title = "Refund queue"
    @users = User.refund_queue

    list_paginated_users users: @users,
                         template: "Admin/RefundQueues/Show",
                         legacy_template: "admin/users/refund_queue"
  end
end
