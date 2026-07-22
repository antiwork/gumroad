# frozen_string_literal: true

require "spec_helper"

describe InstallmentsHelper do
  describe "#post_title_displayable" do
    let(:url) { nil }
    let(:post) { create(:installment) }

    subject { helper.post_title_displayable(post:, url:) }

    context "when url is missing" do
      it "displays the post title as plain text" do
        is_expected.to eq("<span class=\"title\">#{ERB::Util.html_escape(post.subject)}</span>")
      end
    end

    context "when url is present" do
      let(:url) { "https://example.com/p/#{post.slug}" }

      it "displays the post title as an anchor tag" do
        is_expected.to eq("<a target=\"_blank\" class=\"title\" href=\"#{url}\">#{ERB::Util.html_escape(post.subject)}</a>")
      end
    end
  end

  describe "#with_per_block_text_direction" do
    it "returns blank input unchanged" do
      expect(helper.with_per_block_text_direction(nil)).to be_nil
      expect(helper.with_per_block_text_direction("")).to eq("")
    end

    it "adds dir=auto to each top-level text block so mixed-language messages resolve direction per block" do
      html = "<p>Hello</p><p>שלום עולם</p><h2>Heading</h2><ul><li>One</li></ul><blockquote>Quote</blockquote>"
      expect(helper.with_per_block_text_direction(html)).to eq(
        '<p dir="auto">Hello</p><p dir="auto">שלום עולם</p><h2 dir="auto">Heading</h2><ul dir="auto"><li>One</li></ul><blockquote dir="auto">Quote</blockquote>'
      )
    end

    it "leaves code blocks and wrapper divs untouched so code stays left-to-right and embeds keep their layout" do
      html = '<pre><code>var a = 1;</code></pre><div class="item">upsell</div>'
      expect(helper.with_per_block_text_direction(html)).to eq(html)
    end

    it "does not override an explicit dir attribute" do
      html = '<p dir="ltr">Pinned</p>'
      expect(helper.with_per_block_text_direction(html)).to eq(html)
    end
  end
end
