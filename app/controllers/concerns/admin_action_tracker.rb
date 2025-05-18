# frozen_string_literal: true

module AdminActionTracker
  extend ActiveSupport::Concern

  included do
    before_action :track_admin_action_call
  end

  private
    def track_admin_action_call
      AdminActionCallInfo.find_by(controller_name: self.class.name, action_name:)&.increment!(:call_count)
    end
end
