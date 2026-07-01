# frozen_string_literal: true

require "spec_helper"

describe GumclawController do
  render_views

  before { allow(GithubStarsController).to receive(:cached_count).and_return(1234) }

  describe "GET index" do
    context "when career_pages feature is active" do
      before { Feature.activate(:career_pages) }

      it "renders successfully" do
        get :index

        expect(response).to be_successful
        expect(assigns(:title)).to eq("Gumclaw - The agent that runs Gumroad")
        expect(assigns(:hide_layouts)).to be(true)
      end
    end

    context "when career_pages feature is inactive" do
      before { Feature.deactivate(:career_pages) }

      it "returns 404" do
        expect { get :index }.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end
  end
end
