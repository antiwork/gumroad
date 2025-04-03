# frozen_string_literal: true

describe XmlHelpers do
  describe "text_at_xpath" do
    describe "simple xml" do
      let(:xml_raw) { %(<?xml version="1.0" encoding="utf-8"?><root><element>the text</element></root>) }
      let(:xml_document) { REXML::Document.new(xml_raw) }

      it "gets the text of the element" do
        expect(XmlHelpers.text_at_xpath(xml_document, "root/element")).to eq("the text")
      end

      it "returns nil when not found" do
        expect(XmlHelpers.text_at_xpath(xml_document, "root/elements")).to be_nil
      end
    end

    describe "xml with repeating elements" do
      let(:xml_raw) { %(<?xml version="1.0" encoding="utf-8"?><root><element>a text block</element><element>the text</element></root>) }
      let(:xml_document) { REXML::Document.new(xml_raw) }

      it "gets the text of the element of the first" do
        expect(XmlHelpers.text_at_xpath(xml_document, "root/element")).to eq("a text block")
      end
    end
  end
end
