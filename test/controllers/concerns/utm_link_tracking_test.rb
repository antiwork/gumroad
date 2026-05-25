# frozen_string_literal: true

require "test_helper"

class UtmLinkTrackingTest < ActionController::TestCase
  class AnonymousController < ApplicationController
    include UtmLinkTracking

    def action
      head :ok
    end
  end

  tests AnonymousController

  include Devise::Test::ControllerHelpers

  setup do
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw do
      get "action" => "utm_link_tracking_test/anonymous#action"
      post "action" => "utm_link_tracking_test/anonymous#action"
    end
    @request.env["devise.mapping"] = Devise.mappings[:user]
    @seller = users(:named_seller)
    @utm_link = utm_links(:utm_link_for_named_seller)
    @request.cookies[:_gumroad_guid] = "abc123"
    @request.remote_ip = "192.168.0.1"
    Feature.activate_user(:utm_links, @seller)
    @request.host = @seller.subdomain
    @request.path = "/"
    @orig_protect = ActionController::Base.instance_method(:protect_against_forgery?)
    ActionController::Base.define_method(:protect_against_forgery?) { false }
  end

  teardown do
    ActionController::Base.define_method(:protect_against_forgery?, @orig_protect) if @orig_protect
    Feature.deactivate_user(:utm_links, @seller) if @seller
  end

  def matching_utm_params
    {
      utm_source: @utm_link.utm_source,
      utm_medium: @utm_link.utm_medium,
      utm_campaign: @utm_link.utm_campaign,
      utm_content: @utm_link.utm_content,
      utm_term: @utm_link.utm_term
    }
  end

  test "records UTM link visit for matching link" do
    Sidekiq::Testing.inline! do
      assert_no_difference -> { UtmLink.count } do
        assert_difference -> { UtmLinkVisit.count }, 1 do
          get :action, params: matching_utm_params
        end
      end
    end
    visit = @utm_link.utm_link_visits.last
    assert_equal "abc123", visit.browser_guid
    assert_equal "192.168.0.1", visit.ip_address
  end

  test "enqueues UpdateUtmLinkStatsJob on visit" do
    Sidekiq::Testing.fake! do
      UpdateUtmLinkStatsJob.jobs.clear
      get :action, params: matching_utm_params
      assert UpdateUtmLinkStatsJob.jobs.any? { |j| j["args"] == [@utm_link.id] }
    end
  end

  test "does nothing for non-GET requests" do
    assert_no_difference -> { UtmLinkVisit.count } do
      post :action, params: matching_utm_params
    end
  end

  test "does not track UTM link visits when cookies are disabled" do
    @request.cookies[:_gumroad_guid] = nil
    assert_no_difference -> { UtmLinkVisit.count } do
      get :action, params: matching_utm_params
    end
    assert_response :success
  end
end
