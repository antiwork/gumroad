# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("lib/gumroad_cli/products").to_s

describe GumroadCli::Products do
  subject(:products_cli) { described_class.new }

  describe "#custom_html_payload" do
    it "returns an empty string when clearing custom_html" do
      expect(products_cli.send(:custom_html_payload, "")).to eq("")
    end

    it "reads custom_html from a file" do
      file = Tempfile.new("landing.html")
      file.write("<section>Landing</section>")
      file.close

      expect(products_cli.send(:custom_html_payload, file.path)).to eq("<section>Landing</section>")
    ensure
      file&.unlink
    end

    it "raises a Thor error when the custom_html file is missing" do
      expect do
        products_cli.send(:custom_html_payload, "missing-landing.html")
      end.to raise_error(Thor::Error, "Custom HTML file not found: missing-landing.html")
    end
  end
end
