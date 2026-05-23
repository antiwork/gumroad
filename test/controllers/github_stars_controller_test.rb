# frozen_string_literal: true

require "test_helper"

class GithubStarsControllerTest < ActionController::TestCase
  self.described_class = GithubStarsController
  tests GithubStarsController



  context_ GithubStarsController do
  context_ "GET show", :vcr do
  test "renders HTTP success" do
        get :show

        expect(response).to be_successful
        expect(response.content_type).to include("application/json")
        expect(response.parsed_body["stars"]).to eq(5818)
        expect(response.headers["Cache-Control"]).to include("max-age=3600, public")
      end
    end
  end
end
