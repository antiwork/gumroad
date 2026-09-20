# frozen_string_literal: true

require "spec_helper"

describe McpConnectorsController do
  before { allow(GithubStarsController).to receive(:cached_count).and_return(1234) }

  {
    "muse" => "Gumroad for Muse",
    "claude" => "Gumroad for Claude",
    "chatgpt" => "Gumroad for ChatGPT"
  }.each do |client, title|
    it "sets title, description, and canonical for #{client}" do
      get :show, params: { client: }

      expect(response).to be_successful
      expect(assigns(:hide_layouts)).to be(true)

      description = McpConnectorsController::CLIENTS[client][:meta_description]
      page_url = "#{PROTOCOL}://#{DOMAIN}/#{client}"
      tags = controller.send(:meta_tags)

      expect(controller.send(:page_title)).to eq(title)
      expect(tags["title"][:inner_content]).to eq(title)
      expect(tags["meta-name-description"][:content]).to eq(description)
      expect(tags["canonical"][:href]).to eq(page_url)
      expect(tags["meta-property-og-title"][:content]).to eq(title)
      expect(tags["meta-property-og-description"][:content]).to eq(description)
      expect(tags["meta-property-og-url"][:content]).to eq(page_url)
    end
  end
end
