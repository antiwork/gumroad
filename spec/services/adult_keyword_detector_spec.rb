# frozen_string_literal: true

require "spec_helper"

describe AdultKeywordDetector do
  it "classifies adult text as such" do
    ["nude2screen",
     "PussyStuff",
     "abs punch product",
     "futa123",
     "uncensored",
     "Click here for #HotHentaiComics!"].each do |text|
      expect(described_class.adult?(text)).to eq(true)
    end
  end

  it "classifies non-adult text as such" do
    ["squirtle is a Pokémon",
     "small fuéta",
     "Yuri Gagarin was a great astronaut",
     "Tentacle Monster Hat",
     "ns fw"].each do |text|
      expect(described_class.adult?(text)).to eq(false)
    end
  end
end
