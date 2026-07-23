# frozen_string_literal: true

require "spec_helper"

describe UtmLinkTrackingController do
  let(:utm_link) { create(:utm_link) }

  describe "GET show" do
    it "redirects to the utm_link's url" do
      get :show, params: { permalink: utm_link.permalink }

      expect(response).to redirect_to(utm_link.utm_url)
    end
  end
end
