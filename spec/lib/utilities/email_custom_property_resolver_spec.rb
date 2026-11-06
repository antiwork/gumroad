# frozen_string_literal: true

require "spec_helper"

describe EmailCustomPropertyResolver do
  let(:root) { described_class.root_properties(":root { --color: 0 0 0; --font-family: Arial, sans-serif; --border-alpha: 1 }") }

  def style_of(html)
    Nokogiri::HTML(html).at_css("#x")["style"]
  end

  it "replaces var() with the :root value" do
    html = described_class.resolve('<p id="x" style="color: rgb(var(--color)); font-family: var(--font-family)">a</p>', root)
    expect(style_of(html)).to eq("color: rgb(0, 0, 0); font-family: Arial, sans-serif")
  end

  it "lets an ancestor's declaration override :root for its descendants" do
    html = described_class.resolve('<div style="--color: 255 0 0"><p id="x" style="color: rgb(var(--color))">a</p></div>', root)
    expect(style_of(html)).to eq("color: rgb(255, 0, 0)")
  end

  it "resolves a property that references another on the same element" do
    html = described_class.resolve('<p id="x" style="--parent-color: var(--color); border: solid 1px rgb(var(--parent-color) / var(--border-alpha))">a</p>', root)
    expect(style_of(html)).to eq("border: solid 1px rgba(0, 0, 0, 1)")
  end

  it "uses the fallback and leaves an unknown property untouched" do
    html = described_class.resolve('<p id="x" style="color: var(--nope, red); margin: var(--gone)">a</p>', root)
    expect(style_of(html)).to eq("color: red; margin: var(--gone)")
  end

  it "does not follow a self-referencing property forever" do
    html = described_class.resolve('<p id="x" style="--a: var(--a); color: var(--a)">a</p>', root)
    expect(style_of(html)).to eq("color: var(--a)")
  end
end
