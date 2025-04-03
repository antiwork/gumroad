# frozen_string_literal: true

##
# A collection of methods used internally in devise gem.
##

class User
  module DeviseInternal
    def active_for_authentication?
      true
    end

    def confirmation_required?
      email_required? && !confirmed? && email.present?
    end
  end
end
