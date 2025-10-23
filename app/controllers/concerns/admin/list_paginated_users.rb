# frozen_string_literal: true

module Admin::ListPaginatedUsers
  extend ActiveSupport::Concern
  include Pagy::Backend

  RECORDS_PER_PAGE = 5

  private

  def list_paginated_users(users:, template:, legacy_template:)
    pagination, users = pagy_countless(
      users,
      limit: params[:per_page] || RECORDS_PER_PAGE,
      page: params[:page],
      countless_minimal: true
    )

    respond_to do |format|
      format.html do
        render(
          inertia: template,
          props: {
            users: InertiaRails.merge do
              users.map do |user|
                user.as_json(
                  admin: true,
                  impersonatable: policy([:admin, :impersonators, user]).create?
                )
              end
            end,
            pagination:
          },
          legacy_template: legacy_template
        )
      end
      format.json { render json: { users:, pagination: } }
    end
  end
end
