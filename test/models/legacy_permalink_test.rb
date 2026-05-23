# frozen_string_literal: true

require "test_helper"

class LegacyPermalinkTest < ActiveSupport::TestCase
  self.described_class = LegacyPermalink



  context_ LegacyPermalink do
  context_ "validations" do
  context_ "product" do
  test "must be present" do
          expect(build(:legacy_permalink, product: nil)).not_to be_valid
        end
      end

  context_ "permalink" do
  test "must be present" do
          expect(build(:legacy_permalink, permalink: nil)).not_to be_valid
          expect(build(:legacy_permalink, permalink: "")).not_to be_valid
        end

  test "may contain letters" do
          expect(build(:legacy_permalink, permalink: "abcd")).to be_valid
        end

  test "may contain numbers" do
          expect(build(:legacy_permalink, permalink: "1234")).to be_valid
        end

  test "may contain underscores" do
          expect(build(:legacy_permalink, permalink: "_").valid?).to be(true)
        end

  test "may contain dashes" do
          expect(build(:legacy_permalink, permalink: "-").valid?).to be(true)
        end

  test "may not contain illegal characters" do
          expect(build(:legacy_permalink, permalink: ".&*!")).not_to be_valid
        end

  test "must be unique in a case-insensitive way" do
          create(:legacy_permalink, permalink: "custom")

          expect(build(:legacy_permalink, permalink: "custom")).not_to be_valid
          expect(build(:legacy_permalink, permalink: "CUSTOM")).not_to be_valid
        end
      end
    end
  end
end
