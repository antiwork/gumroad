# frozen_string_literal: true

require "test_helper"

class UsersOauthControllerTest < ActionController::TestCase
  self.described_class = Users::OauthController
  tests Users::OauthController



  context_ Users::OauthController do
    render_views
  end
end
