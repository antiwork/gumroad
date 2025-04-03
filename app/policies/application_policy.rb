# frozen_string_literal: true

class ApplicationPolicy
  attr_reader :user, :seller, :record

  def initialize(context, record)
    @context = context
    @user = context.user
    @seller = context.seller
    @record = record

    # It would happen if authenticate_user! is not called before authorize is called, in which case is a bug
    # that needs fixing.
    #
    raise Pundit::NotAuthorizedError, "must be logged in" unless @user
  end
end
