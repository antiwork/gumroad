# frozen_string_literal: true

require "test_helper"

class UtmLinkTrackingControllerTest < ActionController::TestCase
  self.described_class = UtmLinkTrackingController
  tests UtmLinkTrackingController



  context_ UtmLinkTrackingController do
    let(:utm_link) { create(:utm_link) }

    before do
      Feature.activate_user(:utm_links, utm_link.seller)
    end

  context_ "GET show" do
  test "raises error if the :utm_links feature flag is disabled" do
        Feature.deactivate_user(:utm_links, utm_link.seller)

        expect do
          get :show, params: { permalink: utm_link.permalink }
        end.to raise_error(ActionController::RoutingError)
      end

  test "redirects to the utm_link's url" do
        get :show, params: { permalink: utm_link.permalink }

        expect(response).to redirect_to(utm_link.utm_url)
      end
    end
  end
end
