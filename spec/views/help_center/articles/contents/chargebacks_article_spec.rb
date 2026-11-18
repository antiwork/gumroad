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
    expect(text).to include("the deadline above moves to the end of that shorter window so a response still reaches the card provider in time.")
    expect(text).to include("so the dispute is still contested, unless it is under #{minimum}.")
    expect(text).to include("For a dispute under #{minimum} that you haven't sent us information about, we don't respond and the dispute ends here")
    expect(text).to include("If we didn't respond to it because it was under #{minimum}, we emailed you at the time.")
  end

  it "says the form can be revisited until the deadline and is sent once" do
    expect(text).not_to include("You can only submit additional information once.")
    expect(text).to include("Before the deadline, you can come back to the form as often as you like to add files or change what you wrote.")
    expect(text).to include("We send it all to our payment processor in one submission, and nothing can be added after the deadline.")
  end

  it "says we respond to Stripe Connect disputes through the connected account" do
    expect(text).not_to include("you will need to fight this dispute through your respective Stripe or PayPal accounts")
    expect(text).not_to include("that changed when PayPal Connect and Stripe Connect kicked in")
    expect(text).to include("For a Stripe Connect purchase, we handle the dispute the same way as for any other card sale described below, and submit any response through your connected Stripe account.")
    expect(text).to include("rather than responding in your Stripe dashboard: our payment processor accepts only one response per dispute.")
  end

  it "states what a chargeback costs the seller as booked" do
    expect(text).not_to include("covering both the refunded amount and any payment processing fees")
    expect(text).to include("we take what you earned from the sale back out of your Gumroad balance. You don't pay a chargeback fee.")
  end

  it "mentions the email sent for a lost dispute on a product without a refund policy" do
    expect(text).not_to include("you're not informed")
    expect(text).to include("Otherwise, if we don't win it, we email you only when the product has no refund policy, to suggest adding one.")
  end
end
