# frozen_string_literal: true

class Admin::RefundQueuesController < Admin::BaseController
  def show
    @title = "Refund queue"
    @users = User.refund_queue.with_attached_avatar.includes(:admin_manageable_user_memberships, :links, :purchases)

    render inertia: "Admin/RefundQueues/Show",
           props: {
             users: @users.map { |user| user.as_json(admin: true, impersonatable: policy([:admin, :impersonators, user]).create?) }
           },
           legacy_template: "admin/users/refund_queue"
  end
end
