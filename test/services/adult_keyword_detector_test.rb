# frozen_string_literal: true

require "test_helper"

class AdultKeywordDetectorTest < ActiveSupport::TestCase
  test "classifies adult text as such" do
    [
      "nude2screen",
      "PussyStuff",
      "abs punch product",
      "futa123",
      "uncensored",
      "Click here for #HotHentaiComics!",
    ].each do |text|
      assert_equal true, AdultKeywordDetector.adult?(text), "Expected #{text.inspect} to be classified adult"
    end
  end

  test "classifies non-adult text as such" do
    [
      "squirtle is a Pokémon",
      "small fuéta",
      "Yuri Gagarin was a great astronaut",
      "Tentacle Monster Hat",
      "ns fw",
      "Signature Seerie Episode 12 - Saucy",
      "a saucy magic trick",
    ].each do |text|
      assert_equal false, AdultKeywordDetector.adult?(text), "Expected #{text.inspect} to be classified non-adult"
    end
  end
end
