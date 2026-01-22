# frozen_string_literal: true

class Admin::UnreviewedUsersController < Admin::BaseController
  def index
    @title = "Unreviewed users"

    cached_data = Admin::UnreviewedUsersService.cached_users_data

    if cached_data.blank?
      render inertia: "Admin/UnreviewedUsers/Index",
             props: {
               users: [],
               total_count: 0,
               cutoff_date: Admin::UnreviewedUsersService.cutoff_date.to_s
             }
      return
    end

    external_ids = cached_data[:users].map { |u| u[:external_id] }
    still_unreviewed_external_ids = User.where(external_id: external_ids, user_risk_state: "not_reviewed").pluck(:external_id).to_set

    still_unreviewed_users = cached_data[:users].select { |u| still_unreviewed_external_ids.include?(u[:external_id]) }

    render inertia: "Admin/UnreviewedUsers/Index",
           props: {
             users: still_unreviewed_users,
             total_count: cached_data[:total_count],
             cutoff_date: cached_data[:cutoff_date]
           }
  end
end
