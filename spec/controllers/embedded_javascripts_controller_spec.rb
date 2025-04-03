# frozen_string_literal: true

require "spec_helper"

describe EmbeddedJavascriptsController do
  render_views

  describe "overlay" do
    it "returns the correct js" do
      get :overlay, format: :js
      expect(response.body).to match(ActionController::Base.helpers.asset_url(Shakapacker.manifest.lookup!("overlay.js")))
      expect(response.body).to match(ActionController::Base.helpers.stylesheet_pack_tag("overlay.css", protocol: PROTOCOL, host: DOMAIN))
    end
  end

  describe "embed" do
    it "returns the correct js" do
      get :embed, format: :js
      expect(response.body).to match(Shakapacker.manifest.lookup!("embed.js"))
    end
  end
end
