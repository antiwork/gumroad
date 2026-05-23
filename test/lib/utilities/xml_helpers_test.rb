# frozen_string_literal: true

require "test_helper"

class XmlHelpersTest < ActiveSupport::TestCase
  test "text_at_xpath returns the text of an element in simple xml" do
    xml = REXML::Document.new(%(<?xml version="1.0" encoding="utf-8"?><root><element>the text</element></root>))
    assert_equal "the text", XmlHelpers.text_at_xpath(xml, "root/element")
  end

  test "text_at_xpath returns nil when the xpath is not found" do
    xml = REXML::Document.new(%(<?xml version="1.0" encoding="utf-8"?><root><element>the text</element></root>))
    assert_nil XmlHelpers.text_at_xpath(xml, "root/elements")
  end

  test "text_at_xpath returns the text of the first match when elements repeat" do
    xml = REXML::Document.new(%(<?xml version="1.0" encoding="utf-8"?><root><element>a text block</element><element>the text</element></root>))
    assert_equal "a text block", XmlHelpers.text_at_xpath(xml, "root/element")
  end
end
