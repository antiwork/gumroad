# frozen_string_literal: true

# Shared setup for controller tests (ActionController::TestCase).
#
# The test environment intentionally enables CSRF protection
# (config.action_controller.allow_forgery_protection = true in
# config/environments/test.rb) so request/system tests exercise it like
# production. Controller tests can't reasonably supply a real authenticity
# token, though — there's no rendered form to lift it from — and Devise's
# handle_unverified_request signs the user out, so every non-GET action would
# bounce to /login. rspec-rails solved this by disabling forgery protection
# around each controller example (see ControllerExampleGroup); mirror that
# here so ported controller specs behave identically.
#
# Devise::Test::ControllerHelpers provides `sign_in`, backed by a test Warden
# proxy, matching the RSpec suite's
# `config.include Devise::Test::ControllerHelpers, type: :controller`.
class ActionController::TestCase
  include Devise::Test::ControllerHelpers

  setup do
    @_previous_allow_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = false
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @_previous_allow_forgery_protection
  end
end
