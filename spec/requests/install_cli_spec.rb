# frozen_string_literal: true

require "spec_helper"

describe "GET /install-cli.sh" do
  it "redirects to the Gumroad CLI install script on GitHub" do
    get "/install-cli.sh", headers: { "HOST" => DOMAIN }

    expect(response).to have_http_status(:redirect)
    expect(response.location).to eq("https://raw.githubusercontent.com/antiwork/gumroad-cli/refs/heads/main/script/install.sh")
  end
end
