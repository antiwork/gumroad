# frozen_string_literal: true

require "spec_helper"

describe PreorderHelper do
  describe "formatter release time in the seller's timezone" do
    it "returns the proper date based on the timezone" do
      release_at = DateTime.parse("Aug 3rd 2018 11AM")
      seller_timezone = "Pacific Time (US & Canada)"
      expect(helper.displayable_release_at_date(release_at, seller_timezone)).to eq "August 3, 2018"
    end

    it "returns the previous day" do
      release_at = DateTime.parse("Aug 3rd 2018 3AM")
      seller_timezone = "Pacific Time (US & Canada)"
      expect(helper.displayable_release_at_date(release_at, seller_timezone)).to eq "August 2, 2018" # Aug 3rd at 3AM UTC is actually Aug 2nd in PDT
    end

    it "returns the proper time based on the timezone" do
      release_at = DateTime.parse("Aug 3rd 2018 11AM")
      seller_timezone = "Pacific Time (US & Canada)"
      expect(helper.displayable_release_at_time(release_at, seller_timezone)).to eq " 4AM" # 11AM UTC is 4AM PDT; the space before 4 is the result of %l
    end

    it "returns the proper time based on the timezone" do
      release_at = DateTime.parse("Dec 3rd 2018 7AM")
      seller_timezone = "Pacific Time (US & Canada)"
      expect(helper.displayable_release_at_time(release_at, seller_timezone)).to eq "11PM" # 7AM UTC is 11PM PST
    end

    it "returns the proper date and time based on the timezone" do
      release_at = DateTime.parse("Dec 3rd 2018 7AM")
      seller_timezone = "Pacific Time (US & Canada)"
      expect(helper.displayable_release_at_date_and_time(release_at, seller_timezone)).to eq "December 2nd, 11PM PST"
    end

    it "returns the proper date and time based on the timezone (DST)" do
      release_at = DateTime.parse("Aug 3rd 2018 5AM")
      seller_timezone = "Pacific Time (US & Canada)"
      expect(helper.displayable_release_at_date_and_time(release_at, seller_timezone)).to eq "August 2nd, 10PM PDT"
    end

    it "includes the minute in displayable_release_at_date_and_time if it's not 0" do
      release_at = DateTime.parse("Dec 3rd 2018 7:12AM")
      seller_timezone = "Pacific Time (US & Canada)"
      expect(helper.displayable_release_at_date_and_time(release_at, seller_timezone)).to eq "December 2nd, 11:12PM PST"
    end

    it "includes the minute if it's not 0" do
      release_at = DateTime.parse("Dec 3rd 2018 7:12AM")
      seller_timezone = "Pacific Time (US & Canada)"
      expect(helper.displayable_release_at_time(release_at, seller_timezone)).to eq "11:12PM"
    end
  end
end
