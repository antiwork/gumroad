# frozen_string_literal: true

require "spec_helper"

describe Pages::Interpolator do
  let(:product) { create(:product, name: "Test Product", description: "<p>Real <strong>description</strong></p>", price_cents: 1500) }

  describe ".interpolate" do
    it "replaces data-gumroad-field='name' with the product name" do
      html = %(<h1 data-gumroad-field="name">placeholder</h1>)

      result = described_class.interpolate(html, product: product)

      expect(result).to include("<h1 data-gumroad-field=\"name\">Test Product</h1>")
      expect(result).not_to include("placeholder")
    end

    it "replaces data-gumroad-field='price' with the formatted price" do
      html = %(<span data-gumroad-field="price">$0</span>)

      result = described_class.interpolate(html, product: product)

      expect(result).to include(product.price_formatted_verbose)
    end

    it "replaces data-gumroad-field='description' with plain-text description" do
      html = %(<p data-gumroad-field="description">placeholder</p>)

      result = described_class.interpolate(html, product: product)

      expect(result).to include("Real description")
      expect(result).not_to include("<strong>")
    end

    it "wires <a data-gumroad-action='buy'> to message the wrapper instead of navigating itself" do
      html = %(<a data-gumroad-action="buy" href="#">Buy</a>)

      result = described_class.interpolate(html, product: product)

      expect(result).to include(%(href="/l/#{product.unique_permalink}?wanted=true"))
      expect(result).to include("parent.postMessage('gumroad:checkout','*')")
      expect(result).to include("return false")
    end

    it "leaves unknown field markers untouched (graceful fallback)" do
      html = %(<span data-gumroad-field="not-a-real-field">fallback text</span>)

      result = described_class.interpolate(html, product: product)

      expect(result).to include(">fallback text<")
    end

    it "html-escapes interpolated values to prevent XSS" do
      product.update!(name: %(<script>alert("xss")</script>))
      html = %(<h1 data-gumroad-field="name"></h1>)

      result = described_class.interpolate(html, product: product)

      expect(result).not_to include("<script>")
      expect(result).to include("&lt;script&gt;")
    end

    it "interpolates multiple markers in the same document" do
      html = %(
        <h1 data-gumroad-field="name"></h1>
        <span data-gumroad-field="price"></span>
        <a data-gumroad-action="buy" href="#">Buy</a>
      )

      result = described_class.interpolate(html, product: product)

      expect(result).to include("Test Product")
      expect(result).to include(product.price_formatted_verbose)
      expect(result).to include("?wanted=true")
    end

    it "returns the input unchanged when there are no markers" do
      html = "<section><h1>Static page</h1><p>no markers here</p></section>"

      result = described_class.interpolate(html, product: product)

      expect(result).to include("Static page")
      expect(result).to include("no markers here")
    end

    it "returns blank input as-is" do
      expect(described_class.interpolate("", product: product)).to eq("")
      expect(described_class.interpolate(nil, product: product)).to be_nil
    end

    it "wires non-anchor buy elements via onclick without converting them to anchors" do
      html = %(<button data-gumroad-action="buy">Buy</button>)

      result = described_class.interpolate(html, product: product)

      expect(result).to include("parent.postMessage('gumroad:checkout','*')")
      expect(result).to include("return false")
      expect(result).to include("<button")
      expect(result).not_to include("<a")
      expect(result).not_to include("href=")
    end
  end
end
