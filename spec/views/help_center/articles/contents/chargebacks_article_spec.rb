# frozen_string_literal: true

require "spec_helper"

describe "Chargebacks help article" do
  let(:text) { HelpCenter::ArticleText.plain_text(HelpCenter::Article.find_by!(slug: "134-how-does-gumroad-handle-chargebacks")).squish }
  let(:minimum) { "$#{FightDisputeJob::MINIMUM_CONTESTED_AMOUNT_CENTS / 100}" }

  it "tells sellers how to get a response to a dispute below the contest minimum" do
    expect(text).to include("Disputes under #{minimum}: if you want us to respond, submit additional information before the deadline.")
    expect(text).to include("without information from you we don't respond, the dispute is lost, and we email you to let you know.")
    expect(text).to include("If we can't tell that amount, we respond as usual. PayPal disputes aren't affected.")
  end

  it "does not promise a response to every dispute once the deadline passes" do
    expect(text).to include("we will auto-submit on your behalf, except for a dispute under #{minimum} that you haven't sent us information about")
    expect(text).to include("so the dispute is still contested, unless it is under #{minimum}.")
    expect(text).to include("If we didn't respond to it because it was under #{minimum}, we emailed you at the time.")
  end
end
