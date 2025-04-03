# frozen_string_literal: true

class ApplicationRecord < ActiveRecord::Base
  include StrippedFields

  self.abstract_class = true
end
