# frozen_string_literal: true

require "test_helper"

class RobotsControllerTest < ActionController::TestCase
  self.described_class = RobotsController
  tests RobotsController



  context_ RobotsController do
    render_views

  context_ "GET index" do
      before do
        @sitemap_config = "Sitemap: https://example.com/sitemap.xml"
        @user_agent_rules = ["User-agent: *", "Disallow: /purchases/"]

        robots_service = instance_double(RobotsService)
        allow(RobotsService).to receive(:new).and_return(robots_service)
        allow(robots_service).to receive(:sitemap_configs).and_return([@sitemap_config])
        allow(robots_service).to receive(:user_agent_rules).and_return(@user_agent_rules)
      end

  test "renders robots.txt" do
        get :index, format: :txt

        expect(response).to be_successful
        expect(response.body).to include(@sitemap_config)
      end

  test "includes user agent rules" do
        get :index, format: :txt

        expect(response).to be_successful
        @user_agent_rules.each do |rule|
          expect(response.body).to include(rule)
        end
      end
    end
  end
end
