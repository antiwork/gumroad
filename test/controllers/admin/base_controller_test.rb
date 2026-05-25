# frozen_string_literal: true

require "test_helper"

class Admin::BaseControllerTest < ActionController::TestCase
  # Anonymous subclass exposing routes for testing the shared before_actions.
  class AnonymousAdminController < ::Admin::BaseController
    def index_with_policy
      authorize :dummy
      render json: { success: true }
    end
  end

  class TestDummyPolicy < ApplicationPolicy
    def index_with_policy?
      false
    end
  end

  tests AnonymousAdminController
  include Devise::Test::ControllerHelpers

  setup do
    @request.env["devise.mapping"] = Devise.mappings[:user]
    @orig_protect = ActionController::Base.instance_method(:protect_against_forgery?)
    ActionController::Base.define_method(:protect_against_forgery?) { false }
    @admin = users(:admin_user)
    @not_admin = users(:basic_user)
    @not_admin.save! if @not_admin.external_id.blank?

    # Pundit looks up policies via `Module.const_get(:DummyPolicy)` against the
    # controller's ancestors. Always swap the constant to our impl for the
    # duration of this test — `pundit_authorization_test.rb` also defines a
    # top-level `DummyPolicy` (with a different action: `action?` instead of
    # `index_with_policy?`), so the "only define if missing" pattern leaks the
    # wrong policy when that test runs first and we lose
    # `index_with_policy?` here.
    @prev_dummy = Object.const_defined?(:DummyPolicy) ? Object.const_get(:DummyPolicy) : nil
    Object.send(:remove_const, :DummyPolicy) if Object.const_defined?(:DummyPolicy)
    Object.const_set(:DummyPolicy, TestDummyPolicy)
  end

  teardown do
    ActionController::Base.define_method(:protect_against_forgery?, @orig_protect) if @orig_protect
    Object.send(:remove_const, :DummyPolicy) if Object.const_defined?(:DummyPolicy)
    Object.const_set(:DummyPolicy, @prev_dummy) if @prev_dummy
  end

  def with_routes
    with_routing do |routes|
      routes.draw do
        namespace :admin do
          get :index, to: "base_controller_test/anonymous_admin#index"
          get :index_with_policy, to: "base_controller_test/anonymous_admin#index_with_policy"
          get :redirect_to_stripe_dashboard, to: "base_controller_test/anonymous_admin#redirect_to_stripe_dashboard"
          get "/", to: "base_controller_test/anonymous_admin#index", as: :root
        end
        get "/admin", to: "admin/base_controller_test/anonymous_admin#index", as: :admin
        get "/login", to: "logins#new", as: :login
        get "/", to: "home#dashboard", as: :root
      end
      yield
    end
  end

  test "require_admin! returns 404 for xhr request when not logged in" do
    with_routes do
      get :index, xhr: true
      assert_response :not_found
    end
  end

  test "require_admin! returns 404 for json request when not logged in" do
    with_routes do
      get :index, format: :json
      assert_response :not_found
    end
  end

  test "require_admin! redirects to login with next param when not logged in (html)" do
    with_routes do
      @request.path = "/about"
      get :index
      assert_response :redirect
      assert_match %r{/login\?next=}, @response.redirect_url
    end
  end

  test "require_admin! redirects non-admin to root_path without next param" do
    with_routes do
      sign_in @not_admin
      get :index
      assert_response :redirect
      assert_match %r{^http://[^/]+/$}, @response.redirect_url
    end
  end

  test "require_admin! returns 404 for json for non-admin user" do
    with_routes do
      sign_in @not_admin
      get :index, format: :json
      assert_response :not_found
    end
  end

  test "admin user receives the desired response" do
    with_routes do
      sign_in @admin
      get :index
      assert_response :success
      page = JSON.parse(CGI.unescapeHTML(@response.body.match(/data-page="([^"]*)"/)[1]))
      assert_equal "Admin/Base/Index", page["component"]
      assert_equal "Admin", page["props"]["title"]
    end
  end

  test "user_not_authorized renders JSON for JSON request" do
    with_routes do
      sign_in @admin
      get :index_with_policy, format: :json
      assert_response :unauthorized
      body = JSON.parse(@response.body)
      assert_equal false, body["success"]
      assert_equal "You are not allowed to perform this action.", body["error"]
    end
  end

  test "user_not_authorized renders JSON for XHR request" do
    with_routes do
      sign_in @admin
      get :index_with_policy, xhr: true
      assert_response :unauthorized
      body = JSON.parse(@response.body)
      assert_equal false, body["success"]
    end
  end

  test "user_not_authorized redirects for non-JSON request" do
    with_routes do
      sign_in @admin
      get :index_with_policy
      assert_response :redirect
      assert_equal "You are not allowed to perform this action.", flash[:alert]
    end
  end

  test "redirect_to_stripe_dashboard redirects to admin path when user not found" do
    with_routes do
      sign_in @admin
      get :redirect_to_stripe_dashboard, params: { user_identifier: "nonexistent@example.com" }
      assert_response :redirect
      assert_equal "User not found", flash[:alert]
    end
  end

  test "redirect_to_stripe_dashboard redirects to admin path when user has no Stripe account" do
    with_routes do
      sign_in @admin
      get :redirect_to_stripe_dashboard, params: { user_identifier: @not_admin.email }
      assert_response :redirect
      assert_equal "Stripe account not found", flash[:alert]
    end
  end
end
