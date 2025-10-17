# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "User profile page", type: :system, js: true do
  include FillInUserProfileHelpers

  describe "viewing profile", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    let(:creator) { create(:named_user) }

    it "formats links in the creator bio" do
      creator.update!(bio: "Hello!\n\nI'm Mr. Personman! I like https://www.gumroad.com/link, and my email is mister@personman.fr!")
      visit creator.subdomain_with_protocol
      within "main > header" do
        expect(page).to have_text "Hello!\n\nI'm Mr. Personman! I like gumroad.com/link, and my email is mister@personman.fr!"
        expect(page).to have_link "gumroad.com/link", href: "https://www.gumroad.com/link"
        expect(page).to have_link "mister@personman.fr", href: "mailto:mister@personman.fr"
      end
    end

    it "allows impersonating from the profile page when logged in as Gumroad admin" do
      admin = create(:user, is_team_member: true)
      sign_in admin
      visit "/#{creator.username}"
      click_on "Impersonate"
      expect(page).to have_current_path("/dashboard")
      select_disclosure "#{creator.display_name}" do
        expect(page).to have_menuitem("Unbecome")
        click_on "Profile"
      end

      logout
      sleep 1 # Since logout doesn't seem to immediately invalidate the session
      visit "/#{creator.username}"
      expect(page).to_not have_text("Impersonate")
      expect(page).to_not have_text("Unbecome")

      login_as(creator)
      refresh
      expect(page).to_not have_text("Impersonate")
      expect(page).to_not have_text("Unbecome")
    end

    describe "viewing products" do
      it "displays the lowest cost variant's price for a product with variants" do
        recreate_model_indices(Link)
        section = create(:seller_profile_products_section, seller: creator)
        create(:seller_profile, seller: creator, json_data: { tabs: [{ name: "", sections: [section.id] }] })
        product = create(:product, user: creator, price_cents: 300)
        category = create(:variant_category, link: product)
        create(:variant, variant_category: category, price_difference_cents: 300)
        create(:variant, variant_category: category, price_difference_cents: 150)
        create(:variant, variant_category: category, price_difference_cents: 200)
        create(:variant, variant_category: category, price_difference_cents: 50, deleted_at: 1.hour.ago)

        visit "/#{creator.username}"
        wait_for_ajax

        within find_product_card(product) do
          expect(page).to have_selector("[itemprop='price']", text: "$4.50")
        end
      end
    end
  end

  describe "Profile edit buttons" do
    let(:seller) { create(:named_user) }

    context "with switching account to user as admin for seller" do
      include_context "with switching account to user as admin for seller"

      it "doesn't show the profile edit buttons on logged-in user's profile" do
        create(:seller_profile_products_section, seller:)
        visit user_with_role_for_seller.subdomain_with_protocol
        expect(page).not_to have_link("Edit profile")
        expect(page).not_to have_disclosure("Edit section")
        expect(page).not_to have_button("Page settings")
      end
    end

    context "without user logged in" do
      it "doesn't show the profile edit button" do
        create(:seller_profile_products_section, seller:)
        visit seller.subdomain_with_protocol
        expect(page).not_to have_link("Edit profile")
        expect(page).not_to have_disclosure("Edit section")
        expect(page).not_to have_button("Page settings")
      end
    end
  end

  describe "Tabs and Profile sections" do
    let(:seller) { create(:named_user, :eligible_for_service_products) }
    before do
      time = Time.current
      # So that the products get created in a consistent order
      @product1 = create(:product, user: seller, name: "Product 1", price_cents: 2000, created_at: time)
      @product2 = create(:product, user: seller, name: "Product 2", price_cents: 1000, created_at: time + 1)
      @product3 = create(:product, user: seller, name: "Product 3", price_cents: 3000, created_at: time + 2)
      @product4 = create(:product, user: seller, name: "Product 4", price_cents: 3000, created_at: time + 3)
    end

    context "without user logged in" do
      it "displays sections correctly", :elasticsearch_wait_for_refresh do
        create(:seller_profile_products_section, seller:, header: "Section 1", product: @product1)
        create(:seller_profile_products_section, seller:, header: "Section 1", shown_products: [@product1.id, @product2.id, @product3.id, @product4.id])
        create(:seller_profile_products_section, seller:, header: "Section 2", shown_products: [@product1.id, @product4.id], default_product_sort: ProductSortKey::PRICE_DESCENDING)

        create(:published_installment, seller:, shown_on_profile: true)
        posts = create_list(:audience_installment, 2, published_at: Date.yesterday, seller:, shown_on_profile: true)
        create(:seller_profile_posts_section, seller:, header: "Section 3", shown_posts: posts.pluck(:id))

        create(:seller_profile_rich_text_section, seller:, header: "Section 4", text: { type: "doc", content: [{ type: "heading", attrs: { level: 2 }, content: [{ type: "text", text: "Heading" }] }, { type: "paragraph", content: [{ type: "text", text: "Some more text" }] }] })

        create(:seller_profile_subscribe_section, seller:, header: "Section 5")
        create(:seller_profile_featured_product_section, seller:, header: "Section 6", featured_product_id: @product1.id)
        section = create(:seller_profile_featured_product_section, seller:, header: "Section 7", featured_product_id: create(:membership_product_with_preset_tiered_pricing, user: seller).id)

        create(:seller_profile, seller:, json_data: { tabs: [{ name: "Tab", sections: ([section] + seller.seller_profile_sections.to_a[...-1]).pluck(:id) }] })

        visit seller.subdomain_with_protocol
        within_section "Section 1", section_element: :section do
          expect_product_cards_in_order([@product1, @product2, @product3,  @product4])
        end
        within_section "Section 2", section_element: :section do
          expect_product_cards_in_order([@product4, @product1])
        end
        within_section "Section 3", section_element: :section do
          expect(page).to have_link(count: 2)
          posts.each { expect(page).to have_link(_1.name, href: "/p/#{_1.slug}") }
        end
        within_section "Section 4", section_element: :section do
          expect(page).to have_selector("h2", text: "Heading")
          expect(page).to have_text("Some more text")
        end
        within_section "Section 5", section_element: :section do
          fill_in "Your email address", with: "subscriber@gumroad.com"
          click_on "Subscribe"
        end
        expect(page).to have_alert(text: "Check your inbox to confirm your follow request.")
        expect(page).to_not have_text "Subscribe to receive email updates from #{seller.name}"
        within_section "Section 6", section_element: :section do
          expect(page).to have_section("Product 1", section_element: :article)
        end
        within find("main > section:first-of-type", text: "Section 7") do
          expect(page).to have_text "$3 a month"
          expect(page).to have_text "$5 a month"
        end
      end

      it "shows the subscribe block when there are no sections" do
        visit seller.subdomain_with_protocol
        expect(page).to_not have_selector "main > header"
        expect(page).to have_text "Subscribe to receive email updates from #{seller.name}"
        submit_follow_form(with: "hello@example.com")
        wait_for_ajax
        expect(Follower.last.email).to eq "hello@example.com"

        seller.update!(bio: "Hello!")
        visit seller.subdomain_with_protocol
        expect(page).to have_selector "main > header"
      end
    end

    context "with seller logged in" do
      before do
        login_as seller
      end

      def add_section(type)
        all(:disclosure, "Add section").last.select_disclosure do
          click_on type
        end
        sleep 1
        all(:disclosure, "Edit section").last.select_disclosure do
          click_on "Name"
          fill_in "Name", with: "New section"
        end
      end

      def save_changes
        toggle_disclosure "Edit section"
        sleep 1
        wait_for_ajax
      end

      it "shows the subscribe block when there are no sections" do
        visit seller.subdomain_with_protocol
        expect(page).to have_link("Edit profile")
        expect(page).to have_text "Subscribe to receive email updates from #{seller.name}"
        submit_follow_form(with: "hello@example.com")
        expect(page).to have_alert(text: "As the creator of this profile, you can't follow yourself!")

        add_section "Products"
        expect(page).to_not have_text "Subscribe to receive email updates from #{seller.name}"
        wait_for_ajax
        expect(seller.seller_profile_sections.count).to eq 1

        seller.update!(bio: "Hello!")
        visit seller.subdomain_with_protocol
      end

      it "allows adding and deleting sections" do
        section = create(:seller_profile_products_section, seller:, header: "Section 1", shown_products: [@product1.id, @product2.id, @product3.id, @product4.id])
        create(:seller_profile, seller:, json_data: { tabs: [{ name: "", sections: [section.id] }] })
        visit seller.subdomain_with_protocol
        expect(page).to have_link("Edit profile")

        select_disclosure "Edit section" do
          click_on "Name"
          fill_in "Name", with: "New name"
          uncheck "Display above section"
        end
        save_changes
        expect(page).to_not have_section "Section 1"
        expect(page).to_not have_section "New name"
        expect(section.reload.header).to eq "New name"
        expect(section.hide_header?).to eq true

        select_disclosure "Edit section" do
          click_on "Name"
          check "Display above section"
        end
        expect(page).to have_section "New name"
        save_changes
        expect(section.reload.hide_header?).to eq false

        add_section "Products"
        expect(page).to have_disclosure("Edit section", count: 2)
        within_section "New name", section_element: :section do
          select_disclosure "Edit section" do
            click_on "Remove"
          end
        end
        sleep 1
        wait_for_ajax
        expect(page).to have_disclosure("Edit section", count: 1)
        expect(page).to_not have_section "New name"
        expect(seller.seller_profile_sections.reload.sole).to_not eq section
      end

      it "allows copying the link to a section" do
        section = create(:seller_profile_products_section, seller:)
        section2 = create(:seller_profile_posts_section, seller:)
        create(:seller_profile, seller:, json_data: { tabs: [{ name: "Tab 1", sections: [section.id] }, { name: "Tab 2", sections: [section2.id] }] })
        visit "#{seller.subdomain_with_protocol}/?section=#{section2.external_id}"

        expect(page).to have_tab_button "Tab 2", open: true
        select_disclosure "Edit section" do
          # This currently cannot be tested properly as `navigator.clipboard` is `undefined` in Selenium.
          # Attempting to use `Browser.grantPermissions` like in Flexile throws an error saying "Permissions can't be granted in current context."
          expect(page).to have_button "Copy link"
        end
      end

      it "saves tab settings" do
        published_audience_installment = create(:audience_installment, seller:, shown_on_profile: true, published_at: 1.day.ago, name: "Published audience post")
        unpublished_audience_installment = create(:audience_installment, seller:, shown_on_profile: true)
        published_follower_installment = create(:follower_installment, seller:, shown_on_profile: true, published_at: 1.day.ago)

        visit seller.subdomain_with_protocol
        expect(page).to_not have_tab_button

        select_disclosure "Page settings" do
          click_on "Pages"
          click_on "New page"
          set_rich_text_editor_input(find("[aria-label='Page name']"), to_text: "Hi! I'm page!")
          click_on "New page"
          click_on "New page"
          items = all("[role=list][aria-label=Pages] [role=listitem]")
          expect(items.count).to eq 3
          items[0].find("[aria-grabbed]").drag_to items[2], delay: 0.1
          within items[1] do
            click_on "Remove page"
            click_on "No, cancel"
            click_on "Remove page"
            click_on "Yes, delete"
          end
          expect(page).to have_selector("[role=list][aria-label=Pages] [role=listitem]", count: 2)
        end
        toggle_disclosure "Page settings"
        wait_for_ajax
        expect(page).to have_alert(text: "Changes saved!")

        expect(page).to have_tab_button(count: 2)
        expect(page).to have_tab_button "Hi! I'm page!", open: true
        expect(page).to have_tab_button "New page"
        expect(seller.reload.seller_profile.json_data["tabs"]).to eq([{ name: "New page", sections: [] }, { name: "Hi! I'm page!", sections: [] }].as_json)

        add_section "Products"
        add_section "Products"
        select_disclosure "Add section", match: :first do
          click_on "Posts"
        end
        expect(page).to have_disclosure("Edit section", count: 3)

        all(:disclosure_button, "Edit section")[1].click
        click_on "Remove"
        wait_for_ajax
        expect(page).to have_alert(text: "Changes saved!")

        select_tab "New page"
        add_section "Posts"
        wait_for_ajax
        expect(page).to have_alert(text: "Changes saved!")
        expect(page).to have_link(published_audience_installment.name)
        expect(page).to_not have_link(unpublished_audience_installment.name)
        expect(page).to_not have_link(published_follower_installment.name)

        expect(seller.seller_profile_sections.count).to eq 3
        expect(seller.seller_profile.reload.json_data["tabs"]).to eq([
          { name: "New page", sections: [seller.seller_profile_posts_sections.last.id] },
          { name: "Hi! I'm page!", sections: [seller.seller_profile_posts_sections.first.id, seller.seller_profile_products_sections.sole.id] },
        ].as_json)
        expect(seller.seller_profile_posts_sections[0].shown_posts).to eq [published_audience_installment.id]
      end

      it "allows reordering sections" do
        def expect_sections_in_order(*names)
          names.each_with_index { |name, index| expect(page).to have_selector("section:nth-of-type(#{index + 1}) h2", text: name) }
        end
        section1 = create(:seller_profile_products_section, seller:, header: "Section 1")
        section2 = create(:seller_profile_products_section, seller:, header: "Section 2")
        section3 = create(:seller_profile_products_section, seller:, header: "Section 3")
        create(:seller_profile, seller:, json_data: { tabs: [{ name: "", sections: [section1, section2, section3].pluck(:id) }] })
        visit seller.subdomain_with_protocol

        expect_sections_in_order("Section 1", "Section 2", "Section 3")

        within_section "Section 1", section_element: :section do
          expect(page).to have_button "Move section up", disabled: true
          click_on "Move section down"
        end
        expect_sections_in_order("Section 2", "Section 1", "Section 3")

        add_section "Posts"
        expect_sections_in_order("Section 2", "Section 1", "Section 3", "New section")

        within_section "New section", section_element: :section do
          toggle_disclosure "Edit section"
          expect(page).to have_button "Move section down", disabled: true
          click_on "Move section up"
        end
        expect_sections_in_order("Section 2", "Section 1", "New section", "Section 3")
        wait_for_ajax
        expect(page).to have_alert(text: "Changes saved!")

        expect(seller.seller_profile_sections.count).to eq 4
        expect(seller.seller_profile.reload.json_data["tabs"]).to eq([
          { name: "", sections: [section2, section1, seller.seller_profile_posts_sections.sole, section3].pluck(:id) },
        ].as_json)
      end

      it "allows creating products sections" do
        visit seller.subdomain_with_protocol

        add_section "Products"
        click_on "Go back"

        click_on "Products"
        expect(page).to have_checked_field "Add new products by default"
        expect(page).to have_unchecked_field "Show product filters"
        expect(page).not_to have_selector("[aria-label='Filters']")
        [@product1, @product2, @product3, @product4].each { check _1.name }
        expect_product_cards_in_order([@product1, @product2, @product3, @product4])
        drag_product_row(@product1, to: @product2)
        expect_product_cards_in_order([@product2, @product1, @product3,  @product4])
        drag_product_row(@product3, to: @product2)
        uncheck @product2.name
        expect_product_cards_in_order([@product3, @product1,  @product4])

        expect(page).to have_select("Default sort order", options: ["Custom", "Newest", "Highest rated", "Most reviewed", "Price (Low to High)", "Price (High to Low)"], selected: "Custom")
        select "Price (Low to High)", from: "Default sort order"
        expect_product_cards_in_order([@product1, @product4, @product3])
        save_changes

        section = seller.seller_profile_products_sections.reload.sole
        expect(section).to have_attributes(show_filters: false, add_new_products: true, default_product_sort: "price_asc", shown_products: [@product3.id, @product1.id, @product4.id])

        select_disclosure "Edit section" do
          click_on "Products"
          check "Show product filters"
          uncheck "Add new products by default"
        end
        save_changes
        expect(page).to have_selector("[aria-label='Filters']")
        expect(section.reload).to have_attributes(show_filters: true, add_new_products: false)

        refresh
        expect_product_cards_in_order([@product1, @product4, @product3])
      end

      it "allows creating posts sections" do
        create(:published_installment, seller:)
        posts = create_list(:audience_installment, 2, published_at: Date.yesterday, seller:, shown_on_profile: true)
        visit seller.subdomain_with_protocol

        add_section "Posts"
        save_changes

        within_section "New section" do
          expect(page).to have_link(count: 2)
          posts.each { expect(page).to have_link(_1.name, href: "/p/#{_1.slug}") }
        end

        expect(seller.seller_profile_posts_sections.reload.sole).to have_attributes(header: "New section", shown_posts: posts.pluck(:id))

        refresh
        within_section "New section" do
          expect(page).to have_link(count: 2)
          posts.each { expect(page).to have_link(_1.name, href: "/p/#{_1.slug}") }
        end
      end

      it "allows creating rich text sections" do
        visit seller.subdomain_with_protocol

        add_section "Rich text"
        save_changes

        within_section "New section" do
          editor = find("[contenteditable=true]")
          editor.click
          select_disclosure "Text formats" do
            choose "Title"
          end
          editor.send_keys "Heading\nSome more text"
          attach_file(file_fixture("test.jpg")) do
            click_on "Insert image"
          end
        end
        wait_for_ajax
        toggle_disclosure "Edit section" # unfocus editor
        wait_for_ajax
        expect(page).to have_alert(text: "Changes saved!")
        expect(page).to_not have_alert
        section = seller.seller_profile_rich_text_sections.sole
        Selenium::WebDriver::Wait.new(timeout: 10).until { section.reload.text["content"].map { _1["type"] }.include?("image") }
        image_url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{ActiveStorage::Blob.last.key}"
        expected_rich_text = {
          type: "doc",
          content: [
            { type: "heading", attrs: { level: 2 }, content: [{ type: "text", text: "Heading" }] },
            { type: "paragraph", content: [{ type: "text", text: "Some more text" }] },
            { type: "image", attrs: { src: image_url, link: nil } }
          ]
        }.as_json
        expect(section).to have_attributes(header: "New section", text: expected_rich_text)

        refresh
        within_section "New section" do
          expect(page).to have_selector("h2", text: "Heading")
          expect(page).to have_text("Some more text")
          expect(page).to have_image(src: image_url)
        end
      end

      it "allows creating subscribe sections" do
        visit seller.subdomain_with_protocol

        all(:disclosure, "Add section").last.select_disclosure do
          click_on "Subscribe"
        end

        within_section "Subscribe to receive email updates from Gumbot." do
          expect(page).to have_field("Your email address")
          expect(page).to have_button("Subscribe")
        end
        wait_for_ajax

        new_section = seller.seller_profile_sections.sole
        expect(new_section).to have_attributes(header: "Subscribe to receive email updates from Gumbot.", button_label: "Subscribe")

        select_disclosure "Edit section" do
          click_on "Name"
          fill_in "Name", with: "Subscribe now or else"
          click_on "Go back"
          click_on "Button Label"
          fill_in "Button Label", with: "Follow"
        end
        save_changes

        within_section "Subscribe now or else" do
          expect(page).to have_field("Your email address")
          expect(page).to have_button("Follow")
        end

        expect(new_section.reload).to have_attributes(header: "Subscribe now or else", button_label: "Follow")
      end

      it "allows creating featured product sections" do
        visit seller.subdomain_with_protocol
        add_section "Featured Product"
        expect(page).to have_alert(text: "Changes saved!")

        section = seller.seller_profile_sections.sole
        expect(section).to be_a SellerProfileFeaturedProductSection
        expect(section.featured_product_id).to be_nil

        within_disclosure "Edit section" do
          fill_in "Name", with: "My featured product"
        end
        save_changes
        expect(section.reload).to have_attributes(header: "My featured product", featured_product_id: nil)

        select_disclosure "Edit section" do
          click_on "Featured Product"
          select_combo_box_option search: "Product 2", from: "Featured Product"
        end
        within_section "My featured product" do
          expect(page).to have_section "Product 2", section_element: :article
        end
        save_changes
        expect(section.reload).to have_attributes(header: "My featured product", featured_product_id: @product2.id)

        select_disclosure "Edit section" do
          click_on "Featured Product"
          select_combo_box_option search: "Product 3", from: "Featured Product"
        end
        within_section "My featured product" do
          expect(page).to have_section "Product 3", section_element: :article
        end
        save_changes
        expect(section.reload).to have_attributes(header: "My featured product", featured_product_id: @product3.id)
      end

      it "allows creating coffee featured product sections" do
        coffee_product = create(:coffee_product, user: seller, name: "Buy me a coffee", description: "I need caffeine!")

        visit seller.subdomain_with_protocol
        add_section "Featured Product"
        expect(page).to have_alert(text: "Changes saved!")

        section = seller.seller_profile_sections.sole
        expect(section).to be_a SellerProfileFeaturedProductSection
        expect(section.featured_product_id).to be_nil

        within_disclosure "Edit section" do
          fill_in "Name", with: "My featured product"
        end
        save_changes
        expect(section.reload).to have_attributes(header: "My featured product", featured_product_id: nil)

        select_disclosure "Edit section" do
          click_on "Featured Product"
          select_combo_box_option search: "Buy me a coffee", from: "Featured Product"
        end
        within_section "My featured product" do
          expect(page).to_not have_section "Buy me a coffee", section_element: :article
          expect(page).to have_section "Buy me a coffee", section_element: :section
          expect(page).to have_selector("h1", text: "Buy me a coffee")
          expect(page).to have_selector("h3", text: "I need caffeine!")
        end
        save_changes
        expect(section.reload).to have_attributes(header: "My featured product", featured_product_id: coffee_product.id)
      end

      it "allows creating wishlists sections" do
        wishlists = [
          create(:wishlist, name: "First Wishlist", user: seller),
          create(:wishlist, name: "Second Wishlist", user: seller),
        ]
        visit seller.subdomain_with_protocol

        add_section "Wishlists"
        save_changes
        expect(page).to have_text("No wishlists selected")

        section = seller.seller_profile_sections.sole
        expect(section).to be_a SellerProfileWishlistsSection
        expect(section.shown_wishlists).to eq([])

        select_disclosure "Edit section" do
          click_on "Wishlists"
        end
        wishlists.each { check _1.name }
        expect_product_cards_in_order(wishlists)
        drag_product_row(wishlists.first, to: wishlists.second)
        expect_product_cards_in_order(wishlists.reverse)
        save_changes

        expect(section.reload.shown_wishlists).to eq(wishlists.reverse.map(&:id))

        refresh
        expect_product_cards_in_order(wishlists.reverse)

        click_link "First Wishlist"
        expect(page).to have_button("Copy link")
        expect(page).to have_text("First Wishlist")
        expect(page).to have_text(seller.name)
        expect(page).to have_button("Subscribe")
      end
    end
  end
end
