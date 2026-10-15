# frozen_string_literal: true

require "spec_helper"

# The layouts need two keys of the custom context. The Inertia share already builds all of it.
describe "Custom context in the HTML layouts", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:named_seller) }
  let(:document) { Nokogiri::HTML.parse(response.body) }

  before do
    host! DOMAIN
    sign_in seller
  end

  def layout_settings(id) = JSON.parse(document.at_css("##{id}")["data-settings"])

  it "builds the custom context once on an Inertia page" do
    expect(RenderingExtension).to receive(:custom_context).once.and_call_original

    get dashboard_path

    expect(response).to be_successful
    design_settings = layout_settings("design-settings")
    user_agent_info = layout_settings("user-agent-info")
    page_props = JSON.parse(document.at_css("[data-page]")["data-page"]).fetch("props")
    expect(page_props).to include("design_settings" => design_settings, "user_agent_info" => user_agent_info)
    expect(design_settings.dig("font", "name")).to eq("ABC Favorit")
    expect(user_agent_info).to eq("is_mobile" => false)
  end

  it "does not build the custom context on a page that renders the application layout" do
    expect(RenderingExtension).not_to receive(:custom_context)

    get oauth_device_authorization_path

    expect(response).to be_successful
    expect(document.at_css("[data-page]")).to be_nil
    expect(layout_settings("design-settings")).to eq(
      "font" => { "name" => "ABC Favorit", "url" => controller.view_context.font_url("ABCFavorit-Regular.woff2") }
    )
  end
end
