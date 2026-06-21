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
      expect(page).to have_current_path("/products")
      select_disclosure "#{creator.display_name}" do
        expect(page).to have_menuitem("Unbecome")
      end
      toggle_disclosure "#{creator.display_name}", expand: false
      click_on "Profile"

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
        expect(page).not_to have_disclosure_button("Edit section")
        expect(page).not_to have_button("Page settings")
      end
    end

    context "without user logged in" do
      it "doesn't show the profile edit button" do
        create(:seller_profile_products_section, seller:)
        visit seller.subdomain_with_protocol
        expect(page).not_to have_link("Edit profile")
        expect(page).not_to have_disclosure_button("Edit section")
        expect(page).not_to have_button("Page settings")
      end
    end

    context "with seller logged in" do
      before { login_as seller }

      it "shows the profile edit button without inline section controls" do
        create(:seller_profile_products_section, seller:)
        visit seller.subdomain_with_protocol

        expect(page).to have_link("Edit profile", href: profile_url(host: DOMAIN))
        expect(page).not_to have_disclosure_button("Edit section")
        expect(page).not_to have_disclosure_button("Add section")
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
        create(:seller_profile_products_section, seller:, header: "Section 1", shown_products: [@product1.id, @product2.id, @product3.id, @product4.id], add_new_products: false)
        create(:seller_profile_products_section, seller:, header: "Section 2", shown_products: [@product1.id, @product4.id], default_product_sort: ProductSortKey::PRICE_DESCENDING, add_new_products: false)

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
        if page.has_selector?("section", text: "Section 6", wait: 0)
          expect(page).not_to have_text("Subscribe to receive email updates from #{seller.name}", wait: 2)
          within_section "Section 6", section_element: :section do
            expect(page).to have_section("Product 1", section_element: :article)
          end
          within find("main > section:first-of-type", text: "Section 7") do
            expect(page).to have_text "$3 a month"
            expect(page).to have_text "$5 a month"
          end
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
        within_profile_section_editor do
          # Sections live inside a page, so an empty profile needs a page before a section can be added.
          click_on "Add page" if has_text?("Build your profile")
          click_on "Add section"
          click_on type
        end
        wait_for_ajax
      end

      def save_changes
        click_on "Update profile"
        expect(page).to have_alert(text: "Changes saved!")
        wait_for_ajax
      end

      def profile_editor_sections
        within_profile_section_editor { all(:css, "[aria-label$=' section settings']") }
      end

      def profile_editor_pages
        within_profile_section_editor { all(:css, "[role=list][aria-label='Pages'] > [role=listitem]") }
      end

      def drag_row(row, to:, handle: "[aria-grabbed]")
        page.scroll_to row.first(handle), align: :center
        row.first(handle).drag_to to, delay: 0.1
        wait_for_ajax
      end

      def within_profile_section_editor(&block)
        within("section[aria-label='Profile section editor']", &block)
      end

      def within_section_form(name, match: :first, &block)
        within_profile_section_editor do
          within(:css, "[aria-label='#{name} section settings']", match:, &block)
        end
      end

      def within_profile_editor_preview(&block)
        within_section "Preview", section_element: :aside, &block
      end

      def expect_profile_editor_product_cards_in_order(products)
        within_profile_editor_preview do
          expect_product_cards_in_order(products)
        end
      end

      it "shows the subscribe block when there are no sections" do
        visit profile_path
        expect(page).to have_text "Subscribe to receive email updates from #{seller.name}"

        add_section "Products"
        expect(page).to_not have_text "Subscribe to receive email updates from #{seller.name}"
        expect(seller.seller_profile_sections.count).to eq 0
        save_changes
        expect(seller.seller_profile_sections.count).to eq 1

        seller.update!(bio: "Hello!")
        visit profile_path
      end

      it "allows adding and deleting sections" do
        section = create(:seller_profile_products_section, seller:, header: "Section 1", shown_products: [@product1.id, @product2.id, @product3.id, @product4.id])
        create(:seller_profile, seller:, json_data: { tabs: [{ name: "", sections: [section.id] }] })
        visit profile_path

        within_section_form "Section 1" do
          fill_in "Section name", with: "", fill_options: { clear: :backspace }
        end
        within_profile_editor_preview do
          expect(page).to_not have_section "Section 1"
        end
        expect(section.reload.header).to eq "Section 1"
        expect(section.hide_header?).to eq false
        save_changes
        expect(section.reload.header).to eq ""
        expect(section.hide_header?).to eq true

        # With a blank header the form falls back to the section type label ("Products")
        within_section_form "Products" do
          fill_in "Section name", with: "New name", fill_options: { clear: :backspace }
        end
        within_profile_editor_preview { expect(page).to have_section "New name" }
        save_changes
        expect(section.reload.header).to eq "New name"
        expect(section.hide_header?).to eq false

        add_section "Products"
        expect(profile_editor_sections.count).to eq 2
        within_section_form "New name" do
          click_on "Remove section"
        end
        within_modal "Remove New name?" do
          click_on "Yes, remove"
        end
        expect(profile_editor_sections.count).to eq 1
        expect(page).to_not have_section "New name"
        save_changes
        expect(seller.seller_profile_sections.reload.sole).to_not eq section
      end

      it "keeps sections added by another session when saving unrelated settings" do
        section = create(:seller_profile_products_section, seller:, header: "Section 1", shown_products: [@product1.id])
        create(:seller_profile, seller:, json_data: { tabs: [{ name: "", sections: [section.id] }] })
        visit profile_path
        within_section_form "Section 1" do
          expect(page).to have_field("Section name", with: "Section 1")
        end

        # Another tab/device adds a section while this editor holds a now-stale section list.
        concurrent_section = create(:seller_profile_products_section, seller:, header: "Added elsewhere", shown_products: [@product2.id])

        fill_in "Bio", with: "Bio edit that must not touch sections"
        save_changes

        expect(SellerProfileSection.exists?(concurrent_section.id)).to be true
        expect(seller.reload.bio).to eq "Bio edit that must not touch sections"
      end

      it "keeps a settings-only save settings-only even with a rich text section open" do
        rich_text = create(:seller_profile_rich_text_section, seller:, header: "About", text: {})
        create(:seller_profile, seller:, json_data: { tabs: [{ name: "", sections: [rich_text.id] }] })
        visit profile_path
        within_section_form "About" do
          expect(page).to have_field("Section name", with: "About")
        end

        # The mounted rich text editor must not mark the form dirty, or this bio-only save would
        # resend the section list and falsely conflict with the section added below.
        concurrent_section = create(:seller_profile_products_section, seller:, header: "Added elsewhere", shown_products: [@product1.id])

        fill_in "Bio", with: "Bio only, sections untouched"
        save_changes

        expect(SellerProfileSection.exists?(concurrent_section.id)).to be true
        expect(seller.reload.bio).to eq "Bio only, sections untouched"
      end

      it "rejects a pages/sections save when the profile was changed in another session" do
        section = create(:seller_profile_products_section, seller:, header: "Section 1", shown_products: [@product1.id])
        profile = create(:seller_profile, seller:, json_data: { tabs: [{ name: "", sections: [section.id] }] })
        visit profile_path
        within_section_form "Section 1" do
          expect(page).to have_field("Section name", with: "Section 1")
        end

        # Another session adds a section and saves, advancing the profile's version.
        concurrent_section = create(:seller_profile_products_section, seller:, header: "Added elsewhere", shown_products: [@product2.id])
        profile.update!(json_data: { tabs: [{ name: "", sections: [section.id, concurrent_section.id] }] })

        # This (now-stale) session edits its section and saves.
        within_section_form "Section 1" do
          fill_in "Section name", with: "Renamed", fill_options: { clear: :backspace }
        end
        click_on "Update profile"

        expect(page).to have_alert(text: "changed somewhere else")
        # The stale write is rejected wholesale: the other session's section survives and this
        # session's edit is not applied.
        expect(SellerProfileSection.exists?(concurrent_section.id)).to be true
        expect(section.reload.header).to eq "Section 1"
      end

      it "allows copying the link to a section" do
        section = create(:seller_profile_products_section, seller:, header: "Section one")
        section2 = create(:seller_profile_posts_section, seller:, header: "Section two")
        create(:seller_profile, seller:, json_data: { tabs: [{ name: "Tab 1", sections: [section.id] }, { name: "Tab 2", sections: [section2.id] }] })
        visit "#{profile_path}?section=#{section2.external_id}"

        within_profile_section_editor do
          # The ?section= deep link opens the page that holds the section (Tab 2), not the first page.
          expect(page).to have_field("Page name", with: "Tab 2")
          expect(page).to have_selector("h3", text: "Section two")
          expect(page).not_to have_selector("h3", text: "Section one")
          # This currently cannot be tested properly as `navigator.clipboard` is `undefined` in Selenium.
          # Attempting to use `Browser.grantPermissions` like in Flexile throws an error saying "Permissions can't be granted in current context."
          expect(page).to have_button "Copy link"
        end
      end

      it "saves tab settings" do
        published_audience_installment = create(:audience_installment, seller:, shown_on_profile: true, published_at: 1.day.ago, name: "Published audience post")
        unpublished_audience_installment = create(:audience_installment, seller:, shown_on_profile: true)
        published_follower_installment = create(:follower_installment, seller:, shown_on_profile: true, published_at: 1.day.ago)

        visit profile_path
        within_profile_section_editor do
          expect(page).to have_text("Build your profile")
          click_on "Add page"
          fill_in "Page name", with: "Hi! I'm page!"
          click_on "Add page"
        end
        pages = profile_editor_pages
        expect(pages.count).to eq 2
        drag_row(pages[1], to: pages[0], handle: "[data-page-grabbed]")
        within_profile_section_editor do
          click_on "Add page"
        end
        within(profile_editor_pages[2]) do
          click_on "Remove page"
        end
        within_modal "Remove New page?" do
          click_on "Yes, remove"
        end
        pages = profile_editor_pages
        expect(pages.count).to eq 2
        # Removing the open page falls back to the first remaining one, so "New page" is open and "Hi! I'm page!" is collapsed.
        expect(pages[0]).to have_field("Page name", with: "New page")
        expect(pages[0]).to have_button("Collapse page")
        expect(pages[1]).to have_field("Page name", with: "Hi! I'm page!")
        expect(pages[1]).to have_button("Expand page")
        within_profile_editor_preview do
          expect(page).to have_tab_button("New page")
          expect(page).to have_tab_button("Hi! I'm page!")
        end
        expect(seller.reload.seller_profile&.json_data&.dig("tabs")).to be_blank
        save_changes
        expect(seller.reload.seller_profile.json_data["tabs"]).to eq([{ name: "New page", sections: [] }, { name: "Hi! I'm page!", sections: [] }].as_json)

        add_section "Products"
        add_section "Posts"
        expect(page).to have_link(published_audience_installment.name)
        expect(page).to_not have_link(unpublished_audience_installment.name)
        expect(page).to_not have_link(published_follower_installment.name)
        within(profile_editor_pages[1]) { click_on "Expand page" }
        add_section "Products"
        save_changes

        expect(seller.seller_profile_sections.count).to eq 3
        expect(seller.seller_profile.reload.json_data["tabs"]).to eq([
          { name: "New page", sections: [seller.seller_profile_products_sections.first.id, seller.seller_profile_posts_sections.sole.id] },
          { name: "Hi! I'm page!", sections: [seller.seller_profile_products_sections.last.id] },
        ].as_json)
        expect(seller.seller_profile_posts_sections.sole.shown_posts).to eq [published_audience_installment.id]
      end

      it "allows reordering sections" do
        def expect_sections_in_order(*names)
          sections = profile_editor_sections
          expect(sections.count).to be >= names.length
          names.each_with_index { |name, index| expect(sections[index]).to have_selector("h3", text: name) }
        end
        section1 = create(:seller_profile_products_section, seller:, header: "Section 1")
        section2 = create(:seller_profile_products_section, seller:, header: "Section 2")
        section3 = create(:seller_profile_products_section, seller:, header: "Section 3")
        create(:seller_profile, seller:, json_data: { tabs: [{ name: "", sections: [section1, section2, section3].pluck(:id) }] })
        visit profile_path

        expect_sections_in_order("Section 1", "Section 2", "Section 3")

        sections = profile_editor_sections
        drag_row(sections[0], to: sections[1])
        expect_sections_in_order("Section 2", "Section 1", "Section 3")

        add_section "Posts"
        expect_sections_in_order("Section 2", "Section 1", "Section 3", "Posts")

        sections = profile_editor_sections
        drag_row(sections[3], to: sections[2])
        expect_sections_in_order("Section 2", "Section 1", "Posts", "Section 3")
        expect(seller.seller_profile.reload.json_data["tabs"]).to eq([
          { name: "", sections: [section1, section2, section3].pluck(:id) },
        ].as_json)
        save_changes

        expect(seller.seller_profile_sections.count).to eq 4
        expect(seller.seller_profile.reload.json_data["tabs"]).to eq([
          { name: "", sections: [section2, section1, seller.seller_profile_posts_sections.sole, section3].pluck(:id) },
        ].as_json)
      end

      it "allows creating products sections" do
        visit profile_path

        add_section "Products"

        expect(page).to have_checked_field "Add new products by default"
        expect(page).to have_unchecked_field "Show product filters"
        expect(page).not_to have_selector("[aria-label='Filters']")
        [@product1, @product2, @product3, @product4].each do |product|
          check product.name
          wait_for_ajax
        end
        expect_profile_editor_product_cards_in_order([@product1, @product2, @product3, @product4])
        within_section_form "Products" do
          drag_product_row(@product1, to: @product2)
        end
        wait_for_ajax
        expect_profile_editor_product_cards_in_order([@product2, @product1, @product3,  @product4])
        within_section_form "Products" do
          drag_product_row(@product3, to: @product2)
        end
        wait_for_ajax
        uncheck @product2.name
        wait_for_ajax
        expect_profile_editor_product_cards_in_order([@product3, @product1,  @product4])

        expect(page).to have_select("Default sort order", options: ["Custom", "Newest", "Highest rated", "Most reviewed", "Price (Low to High)", "Price (High to Low)"], selected: "Custom")
        select "Price (Low to High)", from: "Default sort order"
        expect_profile_editor_product_cards_in_order([@product1, @product4, @product3])
        save_changes

        section = seller.seller_profile_products_sections.reload.sole
        expect(section).to have_attributes(show_filters: false, add_new_products: true, default_product_sort: "price_asc", shown_products: [@product3.id, @product1.id, @product4.id])

        within_section_form "Products" do
          check "Show product filters"
          uncheck "Add new products by default"
        end
        save_changes
        expect(page).to have_selector("[aria-label='Filters']")
        expect(section.reload).to have_attributes(show_filters: true, add_new_products: false)

        refresh
        expect_profile_editor_product_cards_in_order([@product1, @product4, @product3])
      end

      it "allows creating posts sections" do
        create(:published_installment, seller:)
        posts = create_list(:audience_installment, 2, published_at: Date.yesterday, seller:, shown_on_profile: true)
        visit profile_path

        add_section "Posts"
        within_section_form "Posts" do
          fill_in "Section name", with: "My posts"
        end
        save_changes

        within_profile_editor_preview do
          within_section "My posts", section_element: :section do
            expect(page).to have_link(count: 2)
            posts.each { expect(page).to have_link(_1.name, href: "/p/#{_1.slug}") }
          end
        end

        expect(seller.seller_profile_posts_sections.reload.sole).to have_attributes(header: "My posts", shown_posts: posts.pluck(:id))

        refresh
        within_profile_editor_preview do
          within_section "My posts", section_element: :section do
            expect(page).to have_link(count: 2)
            posts.each { expect(page).to have_link(_1.name, href: "/p/#{_1.slug}") }
          end
        end
      end

      it "allows creating rich text sections" do
        visit profile_path

        add_section "Rich text"
        save_changes

        editor = within_section_form "Rich text" do
          find("[contenteditable=true]").tap(&:click)
        end
        editor.send_keys "Some rich text"
        expect(seller.seller_profile_rich_text_sections.sole.text).to eq({})
        save_changes
        section = seller.seller_profile_rich_text_sections.sole
        expected_rich_text = {
          type: "doc",
          content: [
            { type: "paragraph", content: [{ type: "text", text: "Some rich text" }] }
          ]
        }.as_json
        expect(section).to have_attributes(header: "", text: expected_rich_text)

        within_profile_editor_preview do
          expect(page).to have_text("Some rich text")
        end

        refresh
        within_profile_editor_preview do
          expect(page).to have_text("Some rich text")
        end
      end

      it "reflects unsaved rich text edits in the live preview" do
        visit profile_path

        add_section "Rich text"
        save_changes

        editor = within_section_form "Rich text" do
          find("[contenteditable=true]").tap(&:click)
        end
        editor.send_keys "Live preview text"

        within_profile_editor_preview do
          expect(page).to have_text("Live preview text")
        end
      end

      it "loads an empty rich text section without flagging the form as changed" do
        section = SellerProfileRichTextSection.create!(seller:, json_data: { "text" => {} })
        seller.seller_profile.update!(json_data: { tabs: [{ name: "Tab 1", sections: [section.id] }] })

        visit profile_path

        expect(page).to have_css("[contenteditable=true]")
        expect(page).to have_button("Update profile", disabled: true)
      end

      it "clears the unsaved-changes state after saving a rich text section" do
        visit profile_path

        add_section "Rich text"
        editor = within_section_form "Rich text" do
          find("[contenteditable=true]").tap(&:click)
        end
        editor.send_keys "Hello world"
        save_changes

        expect(page).to have_button("Update profile", disabled: true)
      end

      it "does not flag the form changed when an empty rich text section is only focused and blurred" do
        section = SellerProfileRichTextSection.create!(seller:, json_data: { "text" => {} })
        seller.seller_profile.update!(json_data: { tabs: [{ name: "Tab 1", sections: [section.id] }] })

        visit profile_path

        find("[contenteditable=true]").click
        find_field("Name").click

        expect(page).to have_button("Update profile", disabled: true)
      end

      it "allows creating subscribe sections" do
        visit profile_path

        add_section "Subscribe"

        within_profile_editor_preview do
          within_section "Subscribe to receive email updates from Gumbot.", section_element: :section do
            expect(page).to have_field("Your email address")
            expect(page).to have_button("Subscribe")
          end
        end

        expect(seller.seller_profile_sections.count).to eq 0

        within_section_form "Subscribe to receive email updates from Gumbot." do
          fill_in "Section name", with: "Subscribe now or else"
          fill_in "Button label", with: "Follow"
        end

        within_profile_editor_preview do
          within_section "Subscribe now or else", section_element: :section do
            expect(page).to have_field("Your email address")
            expect(page).to have_button("Follow")
          end
        end

        expect(seller.seller_profile_sections.count).to eq 0
        save_changes
        expect(seller.seller_profile_sections.sole).to have_attributes(header: "Subscribe now or else", button_label: "Follow")
      end

      it "allows creating featured product sections" do
        visit profile_path
        add_section "Featured product"

        expect(seller.seller_profile_sections.count).to eq 0

        within_section_form "Featured product" do
          fill_in "Section name", with: "My featured product"
        end
        save_changes
        section = seller.seller_profile_sections.sole
        expect(section).to be_a SellerProfileFeaturedProductSection
        expect(section).to have_attributes(header: "My featured product", featured_product_id: nil)

        within_section_form "My featured product" do
          select "Product 2", from: "Featured product"
        end
        within_profile_editor_preview do
          within_section "My featured product", section_element: :section do
            expect(page).to have_section "Product 2", section_element: :article
          end
        end
        expect(section.reload).to have_attributes(header: "My featured product", featured_product_id: nil)
        save_changes
        expect(section.reload).to have_attributes(header: "My featured product", featured_product_id: @product2.id)

        within_section_form "My featured product" do
          select "Product 3", from: "Featured product"
        end
        within_profile_editor_preview do
          within_section "My featured product", section_element: :section do
            expect(page).to have_section "Product 3", section_element: :article
          end
        end
        save_changes
        expect(section.reload).to have_attributes(header: "My featured product", featured_product_id: @product3.id)
      end

      it "allows creating coffee featured product sections" do
        coffee_product = create(:coffee_product, user: seller, name: "Buy me a coffee", description: "I need caffeine!")

        visit profile_path
        add_section "Featured product"

        expect(seller.seller_profile_sections.count).to eq 0

        within_section_form "Featured product" do
          fill_in "Section name", with: "My featured product"
        end
        save_changes
        section = seller.seller_profile_sections.sole
        expect(section).to be_a SellerProfileFeaturedProductSection
        expect(section).to have_attributes(header: "My featured product", featured_product_id: nil)

        within_section_form "My featured product" do
          select "Buy me a coffee", from: "Featured product"
        end
        within_profile_editor_preview do
          within_section "My featured product", section_element: :section do
            expect(page).to_not have_section "Buy me a coffee", section_element: :article
            expect(page).to have_section "Buy me a coffee", section_element: :section
            expect(page).to have_selector("h1", text: "Buy me a coffee")
            expect(page).to have_selector("h3", text: "I need caffeine!")
          end
        end
        save_changes
        expect(section.reload).to have_attributes(header: "My featured product", featured_product_id: coffee_product.id)
      end

      it "allows creating wishlists sections" do
        wishlists = [
          create(:wishlist, name: "First Wishlist", user: seller),
          create(:wishlist, name: "Second Wishlist", user: seller),
        ]
        visit profile_path

        add_section "Wishlists"
        save_changes
        expect(page).to have_text("No wishlists selected")

        section = seller.seller_profile_sections.sole
        expect(section).to be_a SellerProfileWishlistsSection
        expect(section.shown_wishlists).to eq([])

        wishlists.each do |wishlist|
          check wishlist.name
          wait_for_ajax
        end
        expect_profile_editor_product_cards_in_order(wishlists)
        within_section_form "Wishlists" do
          drag_product_row(wishlists.first, to: wishlists.second)
        end
        expect_profile_editor_product_cards_in_order(wishlists.reverse)

        expect(section.reload.shown_wishlists).to eq([])
        save_changes
        expect(section.reload.shown_wishlists).to eq(wishlists.reverse.map(&:id))

        refresh
        expect_profile_editor_product_cards_in_order(wishlists.reverse)

        wishlist_href = within_profile_editor_preview { find_link("First Wishlist")[:href] }
        visit wishlist_href
        expect(page).to have_button("Copy link")
        expect(page).to have_text("First Wishlist")
        expect(page).to have_text(seller.name)
        expect(page).to have_button("Subscribe")
      end
    end
  end
end
