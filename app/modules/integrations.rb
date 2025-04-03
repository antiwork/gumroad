# frozen_string_literal: true

module Integrations
  def find_integration_by_name(name)
    active_integrations.by_name(name).first
  end
end
