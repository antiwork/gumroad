# frozen_string_literal: true

require "spec_helper"

describe "Help Center", type: :system, js: true do
  let(:seller) { create(:named_seller) }

  describe "the user is unauthenticated" do
    it "shows the email support button and the contact form trigger" do
      visit "/help"

      expect(page).to have_link("Email support", href: "mailto:support@gumroad.com")
      expect(page).to have_button("Contact support")
      expect(page).not_to have_link("Report a bug")
    end

    it "submits the contact form" do
      visit "/help"

      click_on "Contact support"

      fill_in "Your email", with: "buyer@example.com"
      select "Payouts", from: "What do you need help with?"
      fill_in "Message", with: "My payout hasn't arrived and it's been over a week now."

      click_on "Send message"

      expect(page).to have_text("Message sent!")
      expect(page).to have_text("buyer@example.com")
    end

    it "sends a screenshot that was removed and chosen again as a real email attachment" do
      visit "/help"
      click_on "Contact support"
      fill_in "Your email", with: "buyer@example.com"
      select "Technical issue", from: "What do you need help with?"
      fill_in "Message", with: "The checkout button does nothing when I click it."

      attach_file "Screenshots (optional)", file_fixture("smilie.png")
      expect(page).to have_text("smilie.png (", count: 1)
      click_on "Remove"
      expect(page).not_to have_text("smilie.png")
      attach_file "Screenshots (optional)", file_fixture("smilie.png")
      expect(page).to have_text("smilie.png (", count: 1)

      click_on "Send message"
      expect(page).to have_text("Message sent!")

      # System examples share the test adapter, so pick this submission's job by its message.
      job = ActiveJob::Base.queue_adapter.enqueued_jobs.select do
        _1["arguments"].first == "SupportContactMailer" && _1["arguments"].last.dig("args", 0, "message") == "The checkout button does nothing when I click it."
      end.sole
      wire = JSON.parse(JSON.generate(job.select { |key, _| key.is_a?(String) }))
      expect { ActiveJob::Base.execute(wire) }.to change { ActionMailer::Base.deliveries.size }.by(1)
      attachment = ActionMailer::Base.deliveries.last.attachments.sole
      expect(attachment.filename).to eq("smilie.png")
      expect(attachment.body.decoded).to eq(file_fixture("smilie.png").binread)
    end

    it "keeps an unsent message across a reload and forgets it once sent" do
      visit "/help"
      click_on "Contact support"
      fill_in "Message", with: "Half-written report about a missing payout."
      click_on "Close"

      refresh
      click_on "Contact support"
      expect(page).to have_field("Message", with: "Half-written report about a missing payout.")

      # A new tab is where the next person on a shared browser starts.
      within_window(open_new_window) do
        visit "/help"
        click_on "Contact support"
        expect(page).to have_field("Message", with: "")
      end

      fill_in "Your email", with: "buyer@example.com"
      select "Payouts", from: "What do you need help with?"
      click_on "Send message"
      expect(page).to have_text("Message sent!")

      refresh
      click_on "Contact support"
      expect(page).to have_field("Message", with: "")
    end
  end

  describe "the user is authenticated" do
    before do
      sign_in seller
    end

    it "shows the email support button and prefills the contact form email" do
      visit "/help"

      expect(page).to have_link("Email support", href: "mailto:support@gumroad.com")
      expect(page).not_to have_link("Report a bug")

      click_on "Contact support"

      expect(page).to have_field("Your email", with: seller.email)
    end

    it "shows a saved draft only to the account that wrote it" do
      other_user = create(:user)

      visit "/help"
      click_on "Contact support"
      fill_in "Message", with: "Unsent message from the first account."
      refresh
      click_on "Contact support"
      expect(page).to have_field("Message", with: "Unsent message from the first account.")

      sign_out seller
      visit "/help"
      click_on "Contact support"
      expect(page).to have_field("Your email", with: "")
      expect(page).to have_field("Message", with: "")

      sign_in other_user
      visit "/help"
      click_on "Contact support"
      expect(page).to have_field("Your email", with: other_user.email)
      expect(page).to have_field("Message", with: "")

      sign_in seller
      visit "/help"
      click_on "Contact support"
      expect(page).to have_field("Your email", with: seller.email)
      expect(page).to have_field("Message", with: "Unsent message from the first account.")
    end
  end
end
