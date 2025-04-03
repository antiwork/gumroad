# frozen_string_literal: true

require "spec_helper"

describe SellerProfileRichTextSection do
  describe "validations" do
    it "validates json_data with the correct schema" do
      section = build(:seller_profile_rich_text_section)
      section.json_data["garbage"] = "should not be here"
      schema = JSON.parse(File.read(Rails.root.join("lib", "json_schemas", "seller_profile_rich_text_section.json").to_s))
      expect(JSON::Validator).to receive(:new).with(schema, insert_defaults: true, record_errors: true).and_wrap_original do |original, *args|
        validator = original.call(*args)
        expect(validator).to receive(:validate).with(section.json_data).and_call_original
        validator
      end
      section.validate
      expect(section.errors.full_messages.to_sentence).to eq("The property '#/' contains additional properties [\"garbage\"] outside of the schema when none are allowed")
    end
  end

  it "limits the size of the text object" do
    section = build(:seller_profile_rich_text_section, text: { text: "a" * 500000 })
    expect(section).to_not be_valid
    expect(section.errors.full_messages.to_sentence).to eq "Text is too large"
  end

  describe "iffy ingest" do
    it "triggers iffy ingest when json_data changes" do
      section = create(:seller_profile_rich_text_section)
      expect do
        section.update!(json_data: {
                          text: {
                            content: [
                              { type: "paragraph", content: [{ text: "Rich content text" }] },
                              { type: "image", attrs: { src: "https://example.com/image1.jpg" } },
                              { type: "image", attrs: { src: "https://example.com/image2.jpg" } }
                            ]
                          }
                        })
      end.to change { Iffy::Profile::IngestJob.jobs.size }.by(1)
    end

    it "triggers iffy ingest when header changes" do
      section = create(:seller_profile_rich_text_section)
      expect do
        section.update!(header: "New Header")
      end.to change { Iffy::Profile::IngestJob.jobs.size }.by(1)
    end
  end
end
