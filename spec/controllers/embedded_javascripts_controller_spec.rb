# frozen_string_literal: true

require "spec_helper"

describe EmbeddedJavascriptsController do
  render_views

  describe "overlay" do
    it "returns the correct js" do
      get :overlay, format: :js
      expect(response.body).to include(ActionController::Base.helpers.asset_url("/js/gumroad.js"))
    end
  end

  describe "embed" do
    it "returns the correct js" do
      get :embed, format: :js
      expect(response.body).to include(ActionController::Base.helpers.asset_url("/js/gumroad-embed.js"))
    end
  end
end
