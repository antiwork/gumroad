# frozen_string_literal: true

require "spec_helper"

describe GumclawController do
  render_views

  before { allow(GithubStarsController).to receive(:cached_count).and_return(1234) }

  describe "GET index" do
    it "renders successfully" do
      get :index

      expect(response).to be_successful
      expect(assigns(:title)).to eq("Gumclaw - The agent that runs Gumroad")
      expect(assigns(:hide_layouts)).to be(true)
    end
  end
end
