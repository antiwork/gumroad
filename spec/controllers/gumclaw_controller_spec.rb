# frozen_string_literal: true

require "spec_helper"

describe GumclawController do
  render_views

  before { allow(GithubStarsController).to receive(:cached_count).and_return(1234) }

  describe "GET index" do
    it "renders successfully" do
      get :index

      expect(response).to be_successful
      expect(assigns(:hide_layouts)).to be(true)
    end

    it "sets title, description, and canonical through page meta" do
      get :index

      title = "Gumclaw - The agent that runs Gumroad"
      description = "Gumroad is run by Gumclaw, an autonomous AI agent that handles support, operations, and engineering. Learn how we build at Antiwork."
      tags = controller.send(:meta_tags)

      expect(controller.send(:page_title)).to eq(title)
      expect(tags["title"][:inner_content]).to eq(title)
      expect(tags["meta-name-description"][:content]).to eq(description)
      expect(tags["canonical"][:href]).to eq("#{PROTOCOL}://#{DOMAIN}/gumclaw")
      expect(tags["meta-property-og-title"][:content]).to eq(title)
      expect(tags["meta-property-og-description"][:content]).to eq(description)
      expect(tags["meta-property-og-url"][:content]).to eq("#{PROTOCOL}://#{DOMAIN}/gumclaw")
    end
  end
end
