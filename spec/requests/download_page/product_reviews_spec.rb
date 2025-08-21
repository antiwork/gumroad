# frozen_string_literal: true

require("spec_helper")

describe("Download Page product reviews", type: :system, js: true) do
  let(:product) { create(:product_with_pdf_files_with_size, custom_permalink: "custom") }
  let(:purchase) { create(:purchase_with_balance, link: product, email: "one@gr.test", created_at: 2.years.ago) }
  let(:url_redirect) { purchase.url_redirect }

  it "allows the user to provide a rating regardless of display_product_reviews being enabled for that product" do
    visit("/d/#{url_redirect.token}")
    choose "3 stars"
    click_on "Post review"
    expect(page).to have_alert(text: "Review submitted successfully!")
    expect(purchase.reload.original_product_review.rating).to eq(3)

    product.display_product_reviews = false
    product.save!
    visit("/d/#{url_redirect.token}")
    expect(page).to have_text("Your rating:")
    expect(page).to have_radio_button("3 stars", checked: true)
  end

  it "displays existing rating and allows the user to update it regardless of display_product_reviews being enabled for that product" do
    create(:product_review, purchase:, rating: 4)
    expect(purchase.reload.original_product_review.rating).to eq(4)

    visit("/d/#{url_redirect.token}")
    expect(page).to have_radio_button("4 stars", checked: true)
    click_on "Edit"
    choose "3 stars"
    click_on "Update review"
    expect(page).to have_alert(text: "Review submitted successfully!")
    expect(purchase.reload.original_product_review.rating).to eq(3)

    product.display_product_reviews = false
    product.save!
    visit("/d/#{url_redirect.token}")
    expect(page).to have_text("Your rating:")
    expect(page).to have_radio_button("3 stars", checked: true)
  end

  it "displays and updates the product review of the original purchase in case of recurring purchase of a membership" do
    member = create(:user)
    membership_product = create(:product_with_pdf_files_with_size, is_recurring_billing: true, subscription_duration: :monthly,
                                                                   block_access_after_membership_cancellation: true, price_cents: 100)
    subscription = create(:subscription, link: membership_product)
    original_purchase = create(:purchase_with_balance, link: membership_product, is_original_subscription_purchase: true,
                                                       subscription:, purchaser: member)
    recurring_purchase = create(:purchase_with_balance, link: membership_product, subscription:, purchaser: member)
    subscription.purchases << original_purchase << recurring_purchase
    url_redirect = recurring_purchase.url_redirect

    login_as(member)
    visit("/d/#{url_redirect.token}")
    expect(page).to have_text("Liked it? Give it a rating:")
    choose "3 stars"
    click_on "Post review"
    expect(page).to have_alert(text: "Review submitted successfully!")
    expect(original_purchase.reload.original_product_review.rating).to eq(3)
    expect(original_purchase.original_product_review).to eq(recurring_purchase.reload.original_product_review)

    visit("/d/#{url_redirect.token}")
    expect(page).to have_text("Your rating:")
    expect(page).to have_radio_button("3 stars", checked: true)
    click_on "Edit"
    choose "1 star"
    click_on "Update review"
    expect(page).to have_alert(text: "Review submitted successfully!")
    expect(original_purchase.reload.original_product_review.rating).to eq(1)
  end

  it "does not display or allow the user to review if the purchase is ineligible to submit a review" do
    purchase.update!(purchase_state: "failed")
    visit "/d/#{url_redirect.token}"
    expect(page).not_to have_content "Liked it? Give it a rating:"

    purchase.update!(purchase_state: "successful", should_exclude_product_review: true)
    visit "/d/#{url_redirect.token}"
    expect(page).not_to have_content "Liked it? Give it a rating:"
  end

  context "free trial subscriptions" do
    let(:purchase) { create(:free_trial_membership_purchase) }
    let(:url_redirect) { create(:url_redirect, purchase:) }

    it "allows the user to rate the product after the free trial" do
      purchase.subscription.charge!
      purchase.subscription.update!(free_trial_ends_at: 1.minute.ago)

      visit "/d/#{url_redirect.token}"
      choose "3 stars"
      click_on "Post review"
      expect(page).to have_alert(text: "Review submitted successfully!")
      expect(purchase.reload.original_product_review.rating).to eq(3)
    end
  end

  describe "written reviews" do
    it "allows the user to provide a review" do
      visit purchase.url_redirect.download_page_url

      expect(page).to have_field("Liked it? Give it a rating:", with: "")
      expect(page).to have_button("Post review", disabled: true)
      choose "4 stars"

      fill_in "Want to leave a written review?", with: "This is a great product!"

      click_on "Post review"
      expect(page).to have_alert(text: "Review submitted successfully!")

      expect(page).to_not have_field("Want to leave a written review?")
      expect(page).to have_radio_button("4 stars", checked: true)
      expect(page).to have_text('"This is a great product!"')
      expect(page).to have_button("Edit")

      review = purchase.reload.original_product_review
      expect(review.rating).to eq(4)
      expect(review.message).to eq("This is a great product!")
    end

    context "user has left a review" do
      let!(:review) { create(:product_review, purchase:, rating: 4, message: nil) }

      it "allows the user to update their review" do
        visit purchase.url_redirect.download_page_url

        expect(page).to_not have_field("Want to leave a written review?")
        expect(page).to have_radio_button("4 stars", checked: true)
        expect(page).to have_text("No written review")
        expect(page).to have_button("Edit")

        click_on "Edit"
        fill_in "Want to leave a written review?", with: "This is a great product!"
        choose "5 stars"
        click_on "Update review"

        expect(page).to have_alert(text: "Review submitted successfully!")

        expect(page).to_not have_field("Want to leave a written review?")
        expect(page).to have_radio_button("5 stars", checked: true)
        expect(page).to have_text('"This is a great product!"')
        expect(page).to have_button("Edit")

        review.reload
        expect(review.rating).to eq(5)
        expect(review.message).to eq("This is a great product!")
      end
    end
  end

  context "purchase is over a year old and reviews are disabled after 1 year" do
    before { product.user.update!(disable_reviews_after_year: true) }

    it "doesn't allow reviews and displays a status" do
      visit purchase.url_redirect.download_page_url
      expect(page).to have_radio_button("1 star", disabled: true)
      expect(page).to have_radio_button("2 stars", disabled: true)
      expect(page).to have_radio_button("3 stars", disabled: true)
      expect(page).to have_radio_button("4 stars", disabled: true)
      expect(page).to have_radio_button("5 stars", disabled: true)
      expect(page).to have_field("Want to leave a written review?", disabled: true)
      expect(page).to have_selector("[role='status']", text: "Reviews may not be created or modified for this product 1 year after purchase.")
      expect(page).to have_button("Post review", disabled: true)
    end
  end

  context "purchase is in free trial" do
    let(:purchase) { create(:free_trial_membership_purchase) }

    before { purchase.create_url_redirect! }

    it "doesn't allow reviews and displays a status" do
      visit purchase.url_redirect.download_page_url
      expect(page).to have_radio_button("1 star", disabled: true)
      expect(page).to have_radio_button("2 stars", disabled: true)
      expect(page).to have_radio_button("3 stars", disabled: true)
      expect(page).to have_radio_button("4 stars", disabled: true)
      expect(page).to have_radio_button("5 stars", disabled: true)
      expect(page).to have_field("Want to leave a written review?", disabled: true)
      expect(page).to have_selector("[role='status']", text: "Reviews are not allowed during the free trial period.")
      expect(page).to have_button("Post review", disabled: true)
    end
  end

  context "video reviews" do
    it "allows both text and video reviews" do
      visit purchase.url_redirect.download_page_url

      expect(page).to have_radio_button("Text review")
      expect(page).to have_radio_button("Video review")
    end
  end
end
