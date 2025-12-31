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

    user_ids = cached_data[:users].map { |u| u[:id] }
    still_unreviewed_ids = User.where(id: user_ids, user_risk_state: "not_reviewed").pluck(:id).to_set

    still_unreviewed_users = cached_data[:users].select { |u| still_unreviewed_ids.include?(u[:id]) }

    render inertia: "Admin/UnreviewedUsers/Index",
           props: {
             users: still_unreviewed_users,
             total_count: cached_data[:total_count],
             cutoff_date: cached_data[:cutoff_date]
           }
  end
end
