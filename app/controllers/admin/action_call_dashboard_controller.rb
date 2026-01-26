# frozen_string_literal: true

class Admin::ActionCallDashboardController < Admin::BaseController
  def index
    set_meta_tag(title: "Action Call Dashboard")
    @admin_action_call_infos = AdminActionCallInfo.order(call_count: :desc, controller_name: :asc, action_name: :asc)

    render inertia: "Admin/ActionCallDashboard/Index",
           props: {
             admin_action_call_infos: @admin_action_call_infos.as_json(only: [:id, :controller_name, :action_name, :call_count])
           }
  end
end
