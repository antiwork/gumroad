# frozen_string_literal: true

require "spec_helper"

describe HomeController do
  render_views

  describe "GET features_md" do
    it "returns markdown with the feature list" do
      get :features_md

      expect(response).to be_successful
      expect(response.content_type).to include("text/markdown")
      expect(response.body).to include("# Gumroad features")
      expect(response.body).to include("Digital products")
      expect(response.body).to include("Memberships")
      expect(response.body).to include("REST API")
    end
  end

  describe "GET small_bets" do
    it "renders successfully" do
      get :small_bets

      expect(response).to be_successful
      expect(controller.send(:page_title)).to eq("Small Bets by Gumroad")
      expect(assigns(:hide_layouts)).to be(true)
    end
  end

  describe "GET saas" do
    it "renders successfully" do
      get :saas

      expect(response).to be_successful
      expect(controller.send(:page_title)).to include("Gumroad for SaaS")
      expect(assigns(:hide_layouts)).to be(true)
    end
  end
end
