# frozen_string_literal: true

require("spec_helper")

describe("Product page reviews", js: true, type: :system) do
  include ActionView::Helpers::TextHelper

  def create_review(index, rating)
    purchase = create(:purchase, link: product, full_name: "Purchaser #{index}")
    create(:product_review, rating:, purchase:, message: "This is review #{index}", created_at: index.months.ago)
  end

  let(:product) { create(:product, user: create(:named_seller), custom_permalink: "custom") }

  let!(:review_0) { create_review(0, 2) }
  let!(:review_1) { create_review(1, 3) }
  let!(:review_2) { create_review(2, 4) }
  let!(:review_3) { create_review(3, 1) }
  let!(:review_4) { create_review(4, 2) }
  let!(:review_5) { create_review(5, 5) }

  before(:each) do
    allow(Rails.cache).to receive(:read).and_return(nil)
  end

  it "displays the average rating with reviews count if product reviews are enabled for product" do
    expect(product.reviews_count).to eq(6)
    expect(product.average_rating).to eq(2.8)

    visit product.long_url

    expect(page).to have_text("Ratings")
    expect(page).to have_text(pluralize(product.reviews_count, "rating"))

    expect(page).to have_selector("[aria-label='Ratings histogram']")
    rating_distribution = [1 => 17, 2 => 33, 3 => 17, 4 => 17, 5 => 16]
    ProductReview::PRODUCT_RATING_RANGE.each do |rating|
      expect(page).to have_text(pluralize(rating, "star"))
      expect(page).to have_text("#{rating_distribution[rating]}%")
    end

    product.display_product_reviews = false
    product.save!
    visit product.long_url
    expect(page).not_to have_text("Ratings")
    expect(page).not_to have_text("0 ratings")
  end

  it "allows user to provide rating if already bought and displays the rating regardless of display_product_reviews being enabled for that product" do
    purchaser = create(:user)
    purchase = create(:purchase, link: product, purchaser:)
    login_as(purchaser)

    visit product.long_url

    expect(page).to have_text("Liked it? Give it a rating:")
    choose "3 stars"
    click_on "Post review"

    expect(page).to have_alert(text: "Review submitted successfully!")
    expect(purchase.reload.original_product_review.rating).to eq(3)
    expect(product.reload.reviews_count).to eq(7)
    expect(product.average_rating).to eq(2.9)

    page.evaluate_script "window.location.reload()"

    expect(page).to have_text("Your rating:")
    expect(page).to have_radio_button("3 stars", checked: true)

    product.display_product_reviews = false
    product.save!
    visit product.long_url
    expect(page).to have_text("Your rating:")
  end

  it "displays all the rating stars, without clipping, when a user who has already purchased the product views the page in a tablet-sized viewport", :tablet_view do
    purchaser = create(:user)
    create(:purchase, link: product, purchaser:)
    login_as(purchaser)

    visit product.long_url

    expect(page).to have_text("Liked it? Give it a rating:")
    choose "5 stars"
    expect(page).to have_radio_button("5 stars", checked: true)
  end

  it "displays and updates the product review of the original purchase for a subscription product" do
    purchaser = create(:user)
    subscription_product = create(:subscription_product)
    subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: subscription_product)
    original_purchase = create(:purchase, link: subscription_product, is_original_subscription_purchase: true, subscription:, purchaser:)
    subscription.purchases << original_purchase
    subscription.save!

    login_as(purchaser)
    visit subscription_product.long_url

    expect(page).to have_text("Liked it? Give it a rating:")
    choose "3 stars"
    click_on "Post review"
    expect(page).to have_alert(text: "Review submitted successfully!")

    expect(original_purchase.reload.original_product_review.rating).to eq(3)

    recurring_purchase = create(:purchase, link: subscription_product, subscription:, purchaser:)
    subscription.purchases << recurring_purchase
    subscription.save!
    page.evaluate_script "window.location.reload()"
    wait_for_ajax

    expect(page).to have_text("Your rating:")
    expect(page).to have_radio_button("3 stars", checked: true)
    click_on "Edit"
    choose "2 stars"
    click_on "Update review"
    expect(page).to have_alert(text: "Review submitted successfully!")

    expect(original_purchase.reload.original_product_review.rating).to eq(2)
  end

  it "displays the correctly formatted reviews count text based on the number of reviews" do
    visit product.long_url

    expect(page).to have_text("Ratings")
    expect(page).to have_content(pluralize(product.reviews_count, "rating"))

    allow_any_instance_of(Link).to receive(:rating_stats).and_return(
      count: 100,
      average: 3,
      percentages: [20, 20, 20, 20, 20]
    )

    visit product.long_url

    expect(page).to have_text("Ratings")
    expect(page).to have_content("3\n(100 ratings)\n5 stars\n20%")

    allow_any_instance_of(Link).to receive(:rating_stats).and_return(
      count: 100000,
      average: 3,
      percentages: [20, 20, 20, 20, 20]
    )

    visit product.long_url

    expect(page).to have_text("Ratings")
    expect(page).to have_content("3\n(100K ratings)\n5 stars\n20%")
  end

  it "hides the ability to review product if it's in a preorder status" do
    purchaser = create(:user)
    link = create(:product_with_video_file, price_cents: 600, is_in_preorder_state: true, name: "preorder link")
    good_card = build(:chargeable)
    preorder_product = create(:preorder_link, link:)
    preorder = create(:preorder, preorder_link: preorder_product, seller_id: link.user.id)
    create(:purchase, purchaser:,
                      link:,
                      chargeable: good_card,
                      purchase_state: "in_progress",
                      preorder_id: preorder.id,
                      is_preorder_authorization: true)
    preorder.authorize!
    preorder.mark_authorization_successful!
    login_as(purchaser)

    visit link.long_url

    expect(page).not_to have_text("Ratings")
  end

  describe "written reviews" do
    let(:purchaser) { create(:buyer_user) }
    let!(:purchase) { create(:purchase, link: product, purchaser:) }

    before do
      stub_const("ProductReviewsController::PER_PAGE", 2)
      login_as purchaser
    end

    it "allows the user to provide a review" do
      visit product.long_url

      within_section "You've purchased this product" do
        expect(page).to have_field("Liked it? Give it a rating:", with: "")
        expect(page).to have_button("Post review", disabled: true)
        choose "4 stars"

        fill_in "Want to leave a written review?", with: "This is a great product!"

        click_on "Post review"
      end

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
        visit product.long_url

        expect(page).to_not have_field("Want to leave a written review?")
        expect(page).to have_radio_button("4 stars", checked: true)
        expect(page).to have_text("No written review")
        expect(page).to have_button("Edit")

        within_section "You've purchased this product" do
          click_on "Edit"
          fill_in "Want to leave a written review?", with: "This is a great product!"
          choose "5 stars"
          click_on "Update review"
        end

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

    context "adult keywords in review message" do
      it "displays an error message" do
        visit product.long_url

        within_section "You've purchased this product" do
          fill_in "Want to leave a written review?", with: "SAUCY abs Punch!"
          choose "5 stars"
          click_on "Post review"
        end

        expect(page).to have_alert(text: "Validation failed: Adult keywords are not allowed")
      end
    end

    it "displays written reviews and responses" do
      avatar_url = ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png")
      create :product_review_response,
             product_review: review_3,
             message: "Review response 3",
             created_at: 1.day.ago,
             # All review responses should attribute to the seller regardless of who actually wrote it.
             user: create(:user, name: "Not the seller")


      visit product.long_url

      within_section "Ratings", match: :first do
        within_section "Purchaser 5", match: :first do
          expect(page).to have_selector("[aria-label='5 stars']")
          expect(page).to have_text("This is review 5")
          expect(page).to have_image(src: avatar_url)
          check = first("[aria-label='Verified Buyer']")
          check.hover
          expect(check).to have_tooltip(text: "Verified Buyer")
          expect(page).to_not have_text("New")
        end
        within_section "Purchaser 2", match: :first do
          expect(page).to have_selector("[aria-label='4 stars']")
          expect(page).to have_text("This is review 2")
          expect(page).to have_image(src: avatar_url)
          expect(page).to_not have_text("New")
        end

        expect(page).to_not have_text("Purchaser 1")
        expect(page).to_not have_text("Purchaser 0")
        expect(page).to_not have_text("Purchaser 4")
        expect(page).to_not have_section("Purchaser 3")
        expect(page).to_not have_text("Review response 3")

        click_on "Load more"

        within_section "Purchaser 1", match: :first do
          expect(page).to have_selector("[aria-label='3 stars']")
          expect(page).to have_text("This is review 1")
          expect(page).to have_image(src: avatar_url)
          expect(page).to_not have_text("New")
        end
        within_section "Purchaser 0", match: :first do
          expect(page).to have_selector("[aria-label='2 stars']")
          expect(page).to have_text("This is review 0")
          expect(page).to have_image(src: avatar_url)
          expect(page).to have_text("New")
        end

        expect(page).to_not have_text("Purchaser 4")
        expect(page).to_not have_section("Purchaser 3")
        expect(page).to_not have_text("Review response 3")

        click_on "Load more"

        within_section "Purchaser 4", match: :first do
          expect(page).to have_selector("[aria-label='2 stars']")
          expect(page).to have_text("This is review 4")
          expect(page).to have_image(src: avatar_url)
          expect(page).to_not have_text("New")
        end

        within_section "Purchaser 3", match: :first do
          expect(page).to have_selector("[aria-label='1 star']")
          expect(page).to have_text("This is review 3")
          expect(page).to_not have_text("New")
          expect(page).to have_image(src: avatar_url)
        end
        within_section "Seller", match: :first do
          expect(page).to have_text("Review response 3")
          expect(page).to have_image(src: product.user.avatar_url)
          expect(page).to have_text("Creator")
          expect(page).to_not have_selector("[aria-label='Verified Buyer']")
        end

        expect(page).to_not have_button("Load more")
      end
    end

    it "allows the seller to respond to a review" do
      login_as product.user
      visit product.long_url

      click_on "Add response", match: :first
      fill_in "Add a response to the review", with: "Thank you for your review, Mr. 5!"
      click_on "Submit"
      expect(page).to have_alert(text: "Response submitted successfully!")
      within_section "Seller", match: :first do
        expect(page).to have_text("Thank you for your review, Mr. 5!")
        expect(page).to have_text("Creator")
      end
      expect(review_5.reload.response.message).to eq("Thank you for your review, Mr. 5!")

      click_on "Edit"
      fill_in "Add a response to the review", with: "I hate you, Mr. 5!"
      click_on "Update"
      expect(page).to have_alert(text: "Response updated successfully!")
      within_section "Seller", match: :first do
        expect(page).to have_text("I hate you, Mr. 5!")
        expect(page).to have_text("Creator")
      end
      expect(review_5.reload.response.message).to eq("I hate you, Mr. 5!")

      refresh

      within_section "Seller", match: :first do
        expect(page).to have_text("I hate you, Mr. 5!")
        expect(page).to have_text("Creator")
      end
      expect(page).to have_button("Edit")
    end
  end
end
