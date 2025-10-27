# frozen_string_literal: true

class Admin::RefundQueuesController < Admin::BaseController
  include Admin::ListPaginatedUsers

  def show
    @title = "Refund queue"
    @users = User.refund_queue
                 .with_attached_avatar
                 .includes(:admin_manageable_user_memberships, :links, :purchases)
                 .with_blocked_attributes_for(:form_email, :form_email_domain)

    list_paginated_users users: @users,
                         template: "Admin/RefundQueues/Show",
                         legacy_template: "admin/users/refund_queue"
  end
end
