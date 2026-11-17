# frozen_string_literal: true

require "spec_helper"

describe EmailZeroWidthBorderNormalizer do
  def style_of(style)
    html = described_class.normalize(%(<p id="x" style="#{style}">a</p>))
    Nokogiri::HTML(html).at_css("#x")["style"]
  end

  it "turns a zero-width solid border into none" do
    expect(style_of("margin: 0; border-style: solid; border-width: 0")).to eq("margin: 0; border-style: none; border-width: 0")
    expect(style_of("border-style: solid; border-width: 0px")).to eq("border-style: none; border-width: 0px")
  end

  it "keeps the style of the sides that have a width" do
    expect(style_of("border-style: solid; border-width: 0 0 1px")).to eq("border-style: none none solid; border-width: 0 0 1px")
    expect(style_of("border-style: solid; border-width: 0 1px 0 0")).to eq("border-style: none solid none none; border-width: 0 1px 0 0")
    expect(style_of("border-style: solid none; border-width: 1px 0")).to eq("border-style: solid none; border-width: 1px 0")
    expect(style_of("border-style: solid solid none; border-width: 0 0 1px")).to eq("border-style: none; border-width: 0 0 1px")
  end

  it "leaves a border with a width on every side untouched" do
    expect(style_of("border-style: solid; border-width: 1px")).to eq("border-style: solid; border-width: 1px")
    expect(style_of("border: 1px solid #000")).to eq("border: 1px solid #000")
  end

  it "leaves a style it cannot read side by side untouched" do
    expect(style_of("border-style: solid; border-width: 0; border-top-width: 1px")).to eq("border-style: solid; border-width: 0; border-top-width: 1px")
    expect(style_of("border-style: solid; border-width: calc(1px - 1px)")).to eq("border-style: solid; border-width: calc(1px - 1px)")
    expect(style_of("border-style: solid")).to eq("border-style: solid")
  end
end
