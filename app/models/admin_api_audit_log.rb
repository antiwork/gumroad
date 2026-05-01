# frozen_string_literal: true

class AdminApiAuditLog < ApplicationRecord
  belongs_to :actor_user, class_name: "User"
  belongs_to :admin_api_token

  validates :actor_user, :admin_api_token, :action, :route, :http_method, presence: true
end
