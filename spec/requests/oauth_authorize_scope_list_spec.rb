# frozen_string_literal: true

require "spec_helper"

describe "OAuth authorize scope list", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:named_user) }
  let(:oauth_application) do
    create(
      :oauth_application,
      owner: create(:named_user),
      redirect_uri: "http://#{DOMAIN}/",
      confidential: false,
      scopes: "account edit_profile view_profile"
    )
  end

  before do
    host! DOMAIN
    stub_vite_layout_helpers
    sign_in user
  end

  it "renders a description for every requested scope and no empty bullets" do
    get "/oauth/authorize", params: {
      response_type: "code",
      client_id: oauth_application.uid,
      redirect_uri: oauth_application.redirect_uri,
      scope: "account edit_profile view_profile"
    }

    expect(response).to have_http_status(:ok)
    items = Nokogiri::HTML(response.body).css("ul li").map { |li| li.text.squish }
    expect(items).to include(
      "Full access to your account.",
      "Edit your profile name and bio.",
      "See your profile data."
    )
    expect(items).not_to include("")
    expect(items).to eq(items.compact_blank)
  end

  def stub_vite_layout_helpers
    allow(ViteRuby.instance.manifest).to receive(:resolve_entries).and_return({ stylesheets: ["/vite-test.css"] })
    allow_any_instance_of(ActionView::Base).to receive(:vite_client_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_react_refresh_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_typescript_tag).and_return("")
  end
end
