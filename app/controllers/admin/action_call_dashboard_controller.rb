# frozen_string_literal: true

class Admin::ActionCallDashboardController < Admin::BaseController
  def index
    @admin_action_call_infos = AdminActionCallInfo.order(call_count: :desc, controller_name: :asc, action_name: :asc)
  end
end
