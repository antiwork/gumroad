# frozen_string_literal: true

require("spec_helper")
require "shared_examples/authorize_called"

describe("Posts on seller profile", type: :system, js: true) do
  include FillInUserProfileHelpers

  let(:seller) { create(:named_seller, :with_avatar) }
  let(:buyer) { create(:named_user) }

  before do
    section = create(:seller_profile_posts_section, seller:)
    create(:seller_profile, seller:, json_data: { tabs: [{ name: "", sections: [section.id] }] })
    @product = create(:product, name: "a product", user: seller)

    @visible_product_post = create(:installment, link: @product, published_at: 1.days.ago, shown_on_profile: true)
    @hidden_product_post = create(:installment, link: @product, published_at: 2.days.ago, shown_on_profile: false)
    @standard_post = create(:follower_installment, seller:, published_at: 3.days.ago, shown_on_profile: true)
    @old_product_post = create(:installment, link: @product, published_at: 10.days.ago, shown_on_profile: true)

    @unpublished_audience_post = create(:audience_installment, seller:, shown_on_profile: true)
    @installments = build_list(:audience_installment, 17, seller:, shown_on_profile: true) do |installment, i|
      installment.name = "Audience post #{i + 1}"
      installment.published_at = i.days.ago
      installment.save!
      section.shown_posts << installment.id
    end
    section.save!

    @purchase = create(:purchase, link: @product, seller:, purchaser: buyer, created_at: 6.days.ago)
    @follower = create(:named_user)
    create(:follower, user: seller, email: @follower.email, confirmed_at: Time.current)
  end

  it "shows only the published audience profile posts" do
    def assert_posts
      expect(page).to_not have_link(@visible_product_post.name)
      expect(page).to_not have_link(@hidden_product_post.name)
      expect(page).to_not have_link(@standard_post.name)
      expect(page).to_not have_link(@old_product_post.name)
      expect(page).to_not have_link(@unpublished_audience_post.name)
      (0..16).each do |i|
        expect(page).to have_link(@installments[i].name)
      end
    end

    visit "#{seller.subdomain_with_protocol}"
    assert_posts

    login_as(buyer)
    refresh
    assert_posts
    logout

    login_as(seller)
    refresh
    assert_posts
  end

  describe "a product post slug page" do
    before do
      @new_installments = []
      @new_installments << create(:installment, link: @product,  published_at: 3.days.ago, shown_on_profile: false)
      @new_installments << create(:installment, link: @product, published_at: 4.days.ago, shown_on_profile: true)
      @new_installments << create(:installment, link: @product,  published_at: 5.days.ago, shown_on_profile: true)
    end

    it "shows the content slug page for a shown_on_profile=false product post if logged in as the purchaser" do
      login_as(buyer)
      visit "#{seller.subdomain_with_protocol}/p/#{@hidden_product_post.slug}"

      expect(page).to have_title "#{@hidden_product_post.name} - #{seller.name}"
      expect(page).to have_selector("h1", text: @hidden_product_post.name)
      expect(page).to have_text @hidden_product_post.message
    end

    it "shows the content slug page for a shown_on_profile=false product post if logged out with the right purchase_id" do
      visit "/#{seller.username}/p/#{@hidden_product_post.slug}?purchase_id=#{@purchase.external_id}"

      expect(page).to have_title "#{@hidden_product_post.name} - #{seller.name}"
      expect(page).to have_selector("h1", text: @hidden_product_post.name)
      expect(page).to have_text @hidden_product_post.message
    end

    it "shows the content slug page for a shown_on_profile=false product post to the creator without a purchase_id" do
      login_as seller
      visit "#{seller.subdomain_with_protocol}/p/#{@hidden_product_post.slug}"

      expect(page).to have_title "#{@hidden_product_post.name} - #{seller.name}"
      expect(page).to have_selector("h1", text: @hidden_product_post.name)
      expect(page).to have_text @hidden_product_post.message
    end

    it "shows 'other posts for this product' on a product post page to a customer" do
      login_as(buyer)
      visit "#{seller.subdomain_with_protocol}/p/#{@hidden_product_post.slug}"

      expect(page).to have_link(@visible_product_post.name)
      (2..4).each do |i|
        expect(page).to have_link(@new_installments[i - 2].name)
        expect(page).to have_text(@new_installments[i - 2].published_at.strftime("%B %-d, %Y"))
      end
      expect(page).to_not have_link(@hidden_product_post.name)
      expect(page).to_not have_link(@old_product_post.name)
    end

    it "shows the date in the accurate format" do
      post = create(:installment, link: @product,  published_at: Date.parse("Dec 08 2015"), shown_on_profile: true)
      login_as(buyer)
      visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"

      expect(page).to have_selector("time", text: "December 8, 2015")
    end
  end

  describe "a standard post slug page" do
    it "shows the content slug page for a standard post" do
      login_as(@follower)
      visit "#{seller.subdomain_with_protocol}/p/#{@standard_post.slug}"

      expect(page).to have_selector("h1", text: @standard_post.name)
      expect(page).to have_text @standard_post.message
    end

    it "shows 'recent posts' on a standard post" do
      login_as(@follower)
      visit "#{seller.subdomain_with_protocol}/p/#{@standard_post.slug}"

      expect(page).not_to have_link(@visible_product_post.name)
      expect(page).not_to have_link(@hidden_product_post.name)
      (4..6).each do |i|
        expect(page).to have_link(@installments[i - 4].name)
      end
      expect(page).to_not have_link(@standard_post.name)
    end
  end

  describe "an audience post" do
    describe "following" do
      before do
        @follower_email = generate(:email)
      end

      it "allows a user to follow the seller when logged in" do
        login_as(buyer)
        expect do
          visit "#{seller.subdomain_with_protocol}/p/#{@installments.first.slug}"
          submit_follow_form
          wait_for_ajax
          Follower.where(email: buyer.email).first.confirm!
        end.to change { Follower.active.count }.by(1)
        expect(Follower.last.follower_user_id).to eq buyer.id
      end

      it "allows a visitor to follow the seller when logged out" do
        visit "/#{seller.username}/p/#{@installments.first.slug}"

        expect do
          submit_follow_form(with: @follower_email)
          expect(page).to have_button("Subscribed", disabled: true)
          Follower.find_by(email: @follower_email).confirm!
        end.to change { Follower.active.count }.by(1)
        expect(Follower.last.email).to eq @follower_email
      end
    end

    describe "Comments" do
      let(:post) { @installments.first }
      let(:another_post) { @installments.last }
      let(:commenter) { create(:named_user, :with_avatar) }
      let!(:comment1) { create(:comment, commentable: post, author: post.seller, created_at: 2.months.ago) }
      let!(:comment2) { create(:comment) }
      let!(:comment3) { create(:comment, commentable: another_post, author: commenter) }

      before do
        # Set a different user as the seller of 'another_post'
        another_post.update!(seller: create(:user))
      end

      context "when the 'allow_comments' flag is disabled" do
        before do
          post.update!(allow_comments: false)
        end

        it "does not show comments on the post" do
          visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"

          expect(page).to_not have_text("1 comment")
        end
      end

      it "shows comments on the post" do
        visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"
        within_section "1 comment" do
          expect(page).to have_text(comment1.author.display_name)
          expect(page).to have_selector("time", text: "2 months ago")
          expect(page).to have_text(comment1.content)
          expect(page).to have_text("Creator")
        end

        # as a non-signed in user
        expect(page).to_not have_field("Write a comment")
        expect(page).to have_text("Log in or Register to join the conversation")

        # try commenting as a signed in user
        login_as commenter

        visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"
        expect(page).to have_text("1 comment")

        fill_in("Write a comment", with: "Good article!")
        click_on("Post")
        wait_for_ajax

        expect(page).to have_alert(text: "Successfully posted your comment")
        within_section "2 comments" do
          within "article:nth-child(2)" do
            expect(page).to have_text(commenter.display_name)
            expect(page).to have_selector("time", text: "less than a minute ago")
            expect(page).to have_text("Good article!")
            expect(page).to_not have_text("Creator")
          end
        end

        visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"
        expect(page).to have_text("2 comments")

        # check comments on another post
        visit "#{seller.subdomain_with_protocol}/p/#{another_post.slug}"
        expect(page).to have_text("1 comment")
        expect(page).to have_text(comment3.author.display_name)
        expect(page).to have_text(comment3.content)
      end

      context "when signed in as a comment author" do
        let!(:own_comment) { create(:comment, commentable: post, author: commenter) }

        before do
          login_as commenter
        end

        it "allows the comment author to delete only their comments" do
          visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"

          within_section "2 comments" do
            expect("article:nth-child(1)").to_not have_disclosure("Open comment action menu")

            within "article:nth-child(2)" do
              select_disclosure "Open comment action menu" do
                click_on("Delete")
              end
            end

            expect(page).to have_text("Are you sure?")

            expect do
              click_on("Confirm")
              wait_for_ajax
            end.to change { own_comment.reload.alive? }.from(true).to(false)
          end
          expect(page).to have_alert(text: "Successfully deleted the comment")

          visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"
          expect(page).to have_text("1 comment")
          expect(page).to_not have_text(own_comment.content)
        end

        it "allows the comment author to edit only their comments" do
          visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"

          within_section "2 comments" do
            expect("article:nth-child(1)").to_not have_disclosure("Open comment action menu")

            within "article:nth-child(2)" do
              select_disclosure "Open comment action menu" do
                click_on("Edit")
              end
              fill_in("Write a comment", with: "Good article")
              click_on "Cancel"
              expect(page).to_not have_field("Write a comment")
              expect(page).to have_text(own_comment.content)

              select_disclosure "Open comment action menu" do
                click_on("Edit")
              end
              fill_in("Write a comment", with: "Good article")
              click_on("Update")
              wait_for_ajax
              expect(page).to have_text("Good article")
            end
          end

          expect(page).to have_alert(text: "Successfully updated the comment")

          visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"
          within_section "2 comments" do
            expect(page).to have_selector("article:nth-child(2)", text: "Good article")
          end
        end
      end

      shared_examples_for "delete and update as seller or team member" do
        it "allows the post author to delete any comment" do
          visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"

          select_disclosure "Open comment action menu" do
            click_on("Delete")
          end

          expect(page).to have_text("Are you sure?")

          expect do
            click_on("Confirm")
            wait_for_ajax

            expect(page).to have_alert(text: "Successfully deleted the comment")
          end.to change { comment1.reload.alive? }.from(true).to(false)

          visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"
          expect(page).to have_text("0 comments")
          expect(page).to_not have_text(comment1.content)
        end

        it "allows the post author to edit only their comments" do
          create(:comment, commentable: post)
          visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"

          within_section "2 comments" do
            within "article:nth-child(1)" do
              select_disclosure "Open comment action menu" do
                click_on("Edit")
              end
              fill_in("Write a comment", with: "Good article")
              click_on("Update")
              wait_for_ajax
              expect(page).to have_text("Good article")
            end
          end

          expect(page).to have_alert(text: "Successfully updated the comment")

          within_section "2 comments" do
            visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"
            expect(page).to have_selector("article:nth-child(1)", text: "Good article")

            within "article:nth-child(2)" do
              select_disclosure "Open comment action menu" do
                expect(page).to_not have_button("Edit")
              end
            end
          end
        end
      end

      context "when signed in as a post author" do
        before do
          login_as seller
        end

        include_examples "delete and update as seller or team member"
      end

      context "with switching account to user as admin for seller" do
        include_context "with switching account to user as admin for seller"

        let!(:comment1) { create(:comment, commentable: post, author: user_with_role_for_seller, created_at: 2.months.ago) }

        include_examples "delete and update as seller or team member"
      end

      context "when accessing a post using the link received in the purchase receipt" do
        let(:purchase) { create(:purchase, link: @product, full_name: "John Doe", created_at: 1.second.ago) }
        let(:product_post) { create(:published_installment, link: @product, shown_on_profile: true) }
        let(:seller_post) { create(:seller_installment, seller:, published_at: 1.day.ago) }
        let!(:comment) { create(:comment, commentable: product_post) }

        it "allows the not signed-in user to add comments and edit/delete own comments" do
          visit "#{seller.subdomain_with_protocol}/p/#{product_post.slug}?purchase_id=#{purchase.external_id}"

          within_section "1 comment" do
            # Does not allow editing or deleting others' comments
            expect("article:nth-child(1)").to_not have_disclosure("Open comment action menu")
          end

          # Allows adding a new comment
          fill_in("Write a comment", with: "good article")
          click_on("Post")
          wait_for_ajax
          expect(page).to have_alert(text: "Successfully posted your comment")

          within_section "2 comments" do
            within "article:nth-child(2)" do
              expect(page).to have_text("John Doe")
              expect(page).to have_text("good article")
              select_disclosure "Open comment action menu" do
                click_on("Edit")
              end
              fill_in("Write a comment", with: "Nice article!")
              click_on("Update")
              wait_for_ajax
              expect(page).to have_text("Nice article!")
            end
          end

          expect(page).to have_alert(text: "Successfully updated the comment")

          within_section "2 comments" do
            # Allows deleting own comment
            within "article:nth-child(2)" do
              select_disclosure "Open comment action menu" do
                click_on("Delete")
              end
            end
            expect(page).to have_text("Are you sure?")
            click_on("Confirm")
            wait_for_ajax
            expect(page).to_not have_text("Nice article!")
          end
          expect(page).to have_alert(text: "Successfully deleted the comment")
          expect(page).to have_text("1 comment")
        end

        it "allows posting a comment on a seller post" do
          visit "#{seller.subdomain_with_protocol}/p/#{seller_post.slug}?purchase_id=#{purchase.external_id}"

          fill_in "Write a comment", with: "Received this in my inbox! Nice article!"
          click_on "Post"
          wait_for_ajax

          expect(page).to have_text("Successfully posted your comment")

          page.execute_script("window.location.reload()")

          expect(page).to have_text("1 comment")
          expect(page).to have_text("Received this in my inbox! Nice article!")
        end
      end

      it "disallows posting or updating a comment with an adult keyword" do
        login_as commenter

        # Try posting a comment with an adult keyword
        visit "#{seller.subdomain_with_protocol}/p/#{another_post.slug}"
        expect(page).to have_text("1 comment")

        fill_in("Write a comment", with: "nsfw comment")
        click_on("Post")
        wait_for_ajax
        expect(page).to have_alert(text: "An error occurred while posting your comment - Adult keywords are not allowed")

        visit "#{seller.subdomain_with_protocol}/p/#{another_post.slug}"
        expect(page).to_not have_text("nsfw comment")

        within_section "1 comment" do
          # Try updating an existing comment with an adult keyword
          within "article:nth-child(1)" do
            select_disclosure "Open comment action menu" do
              click_on("Edit")
            end
            fill_in("Write a comment", with: "nsfw comment")
            click_on("Update")
            wait_for_ajax
          end
        end
        expect(page).to have_alert(text: "An error occurred while updating the comment - Adult keywords are not allowed")

        visit "#{seller.subdomain_with_protocol}/p/#{another_post.slug}"
        expect(page).to_not have_text("nsfw comment")
      end

      it "performs miscellaneous validations" do
        login_as commenter

        # Prevents posting a comment bigger than the configured character limit
        visit "#{seller.subdomain_with_protocol}/p/#{another_post.slug}"
        fill_in("Write a comment", with: "a" * 10_001)
        click_on("Post")
        wait_for_ajax
        expect(page).to have_alert(text: "An error occurred while posting your comment - Content is too long (maximum is 10000 characters)")
      end

      it "shows user avatars" do
        # Verify current user's avatar when signed in as the post author
        login_as seller
        visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"
        within_section "Write a comment", section_element: :section do
          expect(page).to have_css("img[src='#{seller.avatar_url}']")
        end

        # Verify current user's avatar when signed in as the comment author
        login_as commenter
        visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"
        within_section "Write a comment", section_element: :section do
          expect(page).to have_css("img[src='#{commenter.avatar_url}']")
        end

        # Verify avatars of comment authors
        create(:comment, commentable: post)
        visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"
        within_section "2 comments" do
          within "article:nth-child(1)" do
            expect(page).to have_css("img[src='#{seller.avatar_url}']")
          end
          within "article:nth-child(2)" do
            expect(page).to have_css("img[src='#{ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png")}']")
          end
        end
      end

      it "shows HTML-escaped comments with clickable hyperlinks in place of plaintext URLs" do
        login_as commenter

        visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"

        fill_in("Write a comment", with: %(    That's a great article!\n\n\n\n\nVisit my website at: https://example.com\n<script type="text/html">console.log("Executing evil script...")</script>   ))
        click_on("Post")
        wait_for_ajax
        expect(page).to have_alert(text: "Successfully posted your comment")
        within_section "2 comments" do
          within "article:nth-child(2)" do
            expect(find("p")[:innerHTML]).to eq %(That's a great article!\n\nVisit my website at: <a href="https://example.com" target="_blank" rel="noopener noreferrer nofollow">https://example.com</a>\n&lt;script type="text/html"&gt;console.log("Executing evil script...")&lt;/script&gt;)

            new_window = window_opened_by { click_link "https://example.com" }
            within_window new_window do
              expect(current_url).to eq("https://example.com/")
            end
          end
        end
      end

      it "paginates comments with nested replies" do
        another_comment = create(:comment, commentable: post, created_at: 1.minute.ago)
        reply1_to_comment1 = create(:comment, parent: comment1, commentable: post)
        reply1_to_another_comment = create(:comment, parent: another_comment, commentable: post, created_at: 1.minute.ago)
        reply2_to_another_comment = create(:comment, parent: another_comment, commentable: post)
        reply_to_another_comment_at_depth_2 = create(:comment, parent: reply1_to_another_comment, commentable: post)
        reply_to_another_comment_at_depth_3 = create(:comment, parent: reply_to_another_comment_at_depth_2, commentable: post)
        reply_to_another_comment_at_depth_4 = create(:comment, parent: reply_to_another_comment_at_depth_3, commentable: post)

        login_as commenter

        # For the testing purpose, let's have only one comment per page
        stub_const("PaginatedCommentsPresenter::COMMENTS_PER_PAGE", 1)

        visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"

        within_section "8 comments" do
          expect(page).to have_selector("article", count: 2)

          within all("article")[0] do
            expect(page).to have_text(comment1.content)

            within all("article")[0] do
              expect(page).to have_text(reply1_to_comment1.content)

              # Make sure that there are no more replies
              expect(page).to_not have_selector("article")
            end
          end

          click_on "Load more comments"
          wait_for_ajax
          expect(page).to have_selector("article", count: 8)
          within all("article")[2] do
            expect(page).to have_text(another_comment.content)

            within all("article")[0] do
              expect(page).to have_text(reply1_to_another_comment.content)

              within all("article")[0] do
                expect(page).to have_text(reply_to_another_comment_at_depth_2.content)

                within all("article")[0] do
                  expect(page).to have_text(reply_to_another_comment_at_depth_3.content)

                  within all("article")[0] do
                    expect(page).to have_text(reply_to_another_comment_at_depth_4.content)

                    # Make sure that there are no more replies
                    expect(page).to_not have_selector("article")
                  end
                end
              end
            end

            within all("article")[4] do
              expect(page).to have_text(reply2_to_another_comment.content)
            end
          end

          # Ensure that no more comments are remained to load more
          expect(page).to_not have_text("Load more comments")
        end
      end

      it "allows posting replies" do
        reply1_to_comment1 = create(:comment, parent: comment1, commentable: post)
        reply_to_comment1_at_depth_2 = create(:comment, parent: reply1_to_comment1, commentable: post)

        login_as commenter

        visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"

        within_section "3 comments" do
          within all("article")[0] do
            expect(page).to have_text(comment1.content)

            within all("article")[0] do
              expect(page).to have_text(reply1_to_comment1.content)

              within all("article")[0] do
                expect(page).to have_text(reply_to_comment1_at_depth_2.content)

                click_on "Reply"
                fill_in("Write a comment", with: "Reply at depth 3")
                click_on("Post")
                wait_for_ajax
                within all("article")[0] do
                  expect(page).to have_text("Reply at depth 3")

                  click_on "Reply"
                  fill_in("Write a comment", with: "Reply at depth 4")
                  click_on("Post")
                  wait_for_ajax
                  within all("article")[0] do
                    expect(page).to have_text("Reply at depth 4")

                    # Verify that there is no way to add a reply at this depth
                    expect(page).to_not have_button "Reply"
                  end
                end
              end
            end

            # Add another reply to the root comment
            click_on "Reply", match: :first
            fill_in("Write a comment", with: "Second reply")
            click_on("Post")
            wait_for_ajax
            within all("article")[4] do
              expect(page).to have_text("Second reply")
            end
          end
        end
        expect(page).to have_alert(text: "Successfully posted your comment")

        within_section "6 comments" do
          visit "#{seller.subdomain_with_protocol}/p/#{post.slug}"

          expect(page).to have_text("Reply at depth 3")
          expect(page).to have_text("Reply at depth 4")
          expect(page).to have_text("Second reply")

          # Delete a reply with descendant replies
          within all("article")[3] do
            select_disclosure "Open comment action menu", match: :first do
              click_on("Delete")
            end
          end
          expect(page).to have_text("Are you sure?")
          click_on("Confirm")
          wait_for_ajax
        end
        expect(page).to have_alert(text: "Successfully deleted the comment")
        expect(page).to_not have_text("Reply at depth 3")
        expect(page).to_not have_text("Reply at depth 4")
        expect(page).to have_text("Second reply")
      end
    end
  end
end
