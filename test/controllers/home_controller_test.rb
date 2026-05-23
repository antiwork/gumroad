# frozen_string_literal: true

require "test_helper"

class HomeControllerTest < ActionController::TestCase
  self.described_class = HomeController
  tests HomeController



  context_ HomeController do
    render_views

    before { allow(GithubStarsController).to receive(:cached_count).and_return(1234) }

  context_ "GET features_md" do
  test "returns markdown with the feature list" do
        get :features_md

        expect(response).to be_successful
        expect(response.content_type).to include("text/markdown")
        expect(response.body).to include("# Gumroad features")
        expect(response.body).to include("Digital products")
        expect(response.body).to include("Memberships")
        expect(response.body).to include("REST API")
      end
    end

  context_ "GET small_bets" do
  test "renders successfully" do
        get :small_bets

        expect(response).to be_successful
        expect(controller.send(:page_title)).to eq("Small Bets by Gumroad")
        expect(assigns(:hide_layouts)).to be(true)
      end
    end

  context_ "GET saas" do
  test "renders successfully" do
        get :saas

        expect(response).to be_successful
        expect(controller.send(:page_title)).to include("Gumroad for SaaS")
        expect(assigns(:hide_layouts)).to be(true)
      end
    end
  end
end
