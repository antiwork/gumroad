# frozen_string_literal: true

class Current < ActiveSupport::CurrentAttributes
  attribute :admin_actor, :admin_token
end
