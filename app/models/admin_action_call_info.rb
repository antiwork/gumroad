# frozen_string_literal: true

class AdminActionCallInfo < ApplicationRecord
  validates_presence_of :controller_name, :action_name
end
