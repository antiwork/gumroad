# frozen_string_literal: true

module AdminActor
  extend ActiveSupport::Concern

  included do
    before_action :clear_current_admin_actor!
    after_action :clear_current_admin_actor!
  end

  private
    def set_current_admin_actor!(actor, admin_token: nil)
      Current.admin_actor = actor
      Current.admin_token = admin_token
    end

    def clear_current_admin_actor!
      Current.admin_actor = nil
      Current.admin_token = nil
    end
end
