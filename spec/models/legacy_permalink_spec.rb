# frozen_string_literal: true

require "spec_helper"

describe LegacyPermalink do
  describe "validations" do
    describe "product" do
      it "must be present" do
        expect(build(:legacy_permalink, product: nil)).to_not be_valid
      end
    end

    describe "permalink" do
      it "must be present" do
        expect(build(:legacy_permalink, permalink: nil)).to_not be_valid
        expect(build(:legacy_permalink, permalink: "")).to_not be_valid
      end

      it "may contain letters" do
        expect(build(:legacy_permalink, permalink: "abcd")).to be_valid
      end

      it "may contain numbers" do
        expect(build(:legacy_permalink, permalink: "1234")).to be_valid
      end

      it "may contain underscores" do
        expect(build(:legacy_permalink, permalink: "_").valid?).to be(true)
      end

      it "may contain dashes" do
        expect(build(:legacy_permalink, permalink: "-").valid?).to be(true)
      end

      it "may not contain illegal characters" do
        expect(build(:legacy_permalink, permalink: ".&*!")).to_not be_valid
      end

      it "must be unique in a case-insensitive way" do
        create(:legacy_permalink, permalink: "custom")

        expect(build(:legacy_permalink, permalink: "custom")).to_not be_valid
        expect(build(:legacy_permalink, permalink: "CUSTOM")).to_not be_valid
      end
    end
  end
end
