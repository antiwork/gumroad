# frozen_string_literal: true

require "spec_helper"

describe "InertiaRendering shared props", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:user) }

  before do
    allow_any_instance_of(ActionDispatch::Request).to receive(:host).and_return(VALID_REQUEST_HOSTS.first)
    sign_in seller
  end

  def inertia_props(headers = {})
    get published_emails_path, headers: { "X-Inertia" => "true", "X-Requested-With" => "XMLHttpRequest" }.merge(headers)
    expect(response).to be_successful
    response.parsed_body.fetch("props")
  end

  def partial_reload_headers(data)
    { "X-Inertia-Partial-Component" => "Emails/Published", "X-Inertia-Partial-Data" => data }
  end

  it "shares the whole custom context and the request keys on a full visit" do
    custom_context = nil
    allow(RenderingExtension).to receive(:custom_context).and_wrap_original do |original, *args|
      custom_context = original.call(*args)
    end

    props = inertia_props

    expect(props).to include(custom_context.as_json)
    expect(props["logged_in_user"]).to include("email" => seller.email)
    expect(props).to include("authenticity_token", "flash", "title", "prompt_passkey_setup")
    expect(props["current_user"]).to include("name" => seller.display_name)
  end

  it "skips building the shared props on a partial reload that does not request them" do
    expect(RenderingExtension).not_to receive(:custom_context)
    expect_any_instance_of(EmailsController).not_to receive(:current_user_props)

    props = inertia_props(partial_reload_headers("pagination"))

    expect(props).to have_key("pagination")
    expect(props).not_to have_key("logged_in_user")
  end

  it "builds a shared prop that a partial reload requests" do
    props = inertia_props(partial_reload_headers("logged_in_user"))

    expect(props["logged_in_user"]).to include("email" => seller.email)
    expect(props).not_to have_key("current_seller")
  end
end
