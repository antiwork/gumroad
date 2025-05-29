# frozen_string_literal: true

class ApplicationPolicy
  attr_reader :user, :seller, :record

  class_attribute :allow_anonymous_user_access, default: false

  class << self
    def allow_anonymous_user_access!
      self.allow_anonymous_user_access = true
    end
  end

  def initialize(context, record)
    @context = context
    @user = context.user
    @seller = context.seller
    @record = record

    # It would happen if authenticate_user! is not called before authorize is called, in which case is a bug
    # that needs fixing.
    #
    if !@user && !allow_anonymous_user_access
      raise Pundit::NotAuthorizedError, "must be logged in"
    end
  end

  private
    # Still a bit torn on this -- this allows running the role-based policy
    # checks and skipping record-specific logic when an actual record is not
    # available.
    def when_record_available(&block)
      record.is_a?(Class) || block.call
    end
end
