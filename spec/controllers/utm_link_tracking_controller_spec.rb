# frozen_string_literal: true

require "spec_helper"

describe UtmLinkTrackingController do
  let(:utm_link) { create(:utm_link) }

  before do
    Feature.activate_user(:utm_links, utm_link.seller)
  end

  describe "GET show" do
    it "raises error if the :utm_links feature flag is disabled" do
      Feature.deactivate_user(:utm_links, utm_link.seller)

      expect do
        get :show, params: { permalink: utm_link.permalink }
      end.to raise_error(ActionController::RoutingError)
    end

    it "redirects to the utm_link's url" do
      get :show, params: { permalink: utm_link.permalink }

      expect(response).to redirect_to(utm_link.utm_url)
    end
  end
end
