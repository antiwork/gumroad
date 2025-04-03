# frozen_string_literal: true

require "spec_helper"

describe RichContentImagesRetrievalService do
  describe "#parse" do
    context "when the content is JSON" do
      let(:content) do
        [
          { "type" => "paragraph", "content" => [{ "text" => "hello", "type" => "text" }] },
          { "type" => "image", "attrs" => { "src" => "https://staging-public-files.gumroad.com/z8jxd3vlttx01rh239djq2h90l63", "link" => nil, "class" => nil }, "content" => [{ "text" => "this is a ", "type" => "text" }, { "text" => "caption", "type" => "text", "marks" => [{ "type" => "bold" }] }] },
          { "type" => "paragraph", "content" => [{ "text" => "Another image", "type" => "text" }] },
          { "type" => "image", "attrs" => { "src" => "https://staging-public-files.gumroad.com/6x5sjna68ctvsjfk134hqq15uo2q", "link" => nil, "class" => nil } },
          { "type" => "image", "attrs" => { "src" => "https://staging-public-files.gumroad.com/dgal4aqiybocfu81c1thqoy35eqq", "link" => "https://example.com/", "class" => nil } },
          { "type" => "paragraph" }
        ]
      end
      subject(:service) { described_class.new(content:, is_json: true) }

      it "returns an array of image URLs" do
        expect(service.parse).to eq([
                                      "https://staging-public-files.gumroad.com/z8jxd3vlttx01rh239djq2h90l63",
                                      "https://staging-public-files.gumroad.com/6x5sjna68ctvsjfk134hqq15uo2q",
                                      "https://staging-public-files.gumroad.com/dgal4aqiybocfu81c1thqoy35eqq"
                                    ])
      end
    end

    context "when the content is HTML" do
      let(:content) do
        <<~HTML
          <p>Hello</p>
          <figure><img src="https://staging-public-files.gumroad.com/oiwksjpy5h3ow7nn7ophq36qrtgd"></figure>
          <p>Another <strong>image:</strong></p>
          <figure><img src="https://staging-public-files.gumroad.com/rfjxqc8d2tkoi1oof2mucy0mf0f3"><p class="figcaption">This is a <strong>caption</strong></p></figure>
          <figure><a href="https://example.com/" target="_blank" rel="noopener noreferrer nofollow"><img src="https://staging-public-files.gumroad.com/en01t8ualsvbt0j1y6xc73uuibem" link="https://example.com/"></a><p class="figcaption"></p></figure>
          <img>
          <p>Thanks!</p>
        HTML
      end
      subject(:service) { described_class.new(content:, is_json: false) }

      it "returns an array of image URLs" do
        expect(service.parse).to eq([
                                      "https://staging-public-files.gumroad.com/oiwksjpy5h3ow7nn7ophq36qrtgd",
                                      "https://staging-public-files.gumroad.com/rfjxqc8d2tkoi1oof2mucy0mf0f3",
                                      "https://staging-public-files.gumroad.com/en01t8ualsvbt0j1y6xc73uuibem"
                                    ])
      end
    end
  end
end
