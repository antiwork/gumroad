# frozen_string_literal: true

require "spec_helper"

describe MuseController do
  before { allow(GithubStarsController).to receive(:cached_count).and_return(1234) }

  describe "GET index" do
    it "sets title, description, and canonical through page meta" do
      get :index

      expect(response).to be_successful
      expect(assigns(:hide_layouts)).to be(true)

      title = "Gumroad for Muse"
      description = "Connect Muse to Gumroad. Creators can ask Muse to list sales, draft a product, publish it, and check payouts."
      tags = controller.send(:meta_tags)

      expect(controller.send(:page_title)).to eq(title)
      expect(tags["title"][:inner_content]).to eq(title)
      expect(tags["meta-name-description"][:content]).to eq(description)
      expect(tags["canonical"][:href]).to eq("#{PROTOCOL}://#{DOMAIN}/muse")
      expect(tags["meta-property-og-title"][:content]).to eq(title)
      expect(tags["meta-property-og-description"][:content]).to eq(description)
      expect(tags["meta-property-og-url"][:content]).to eq("#{PROTOCOL}://#{DOMAIN}/muse")
    end
  end
end
