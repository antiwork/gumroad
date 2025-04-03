# frozen_string_literal: true

class SignupEvent < Event
  belongs_to :user, optional: true
  self.table_name = "signup_events"
end
