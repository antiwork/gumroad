# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/creator_dashboard_page"

describe "UTM links", :js, type: :system do
  let(:seller) { create(:user) }

  before do
    Feature.activate_user(:utm_links, seller)
  end

  describe "dashboard" do
    include_context "with switching account to user as admin for seller"

    describe "listing page" do
      it_behaves_like "creator dashboard page", "Analytics" do
        let(:path) { utm_links_dashboard_path }
      end

      it "shows the empty state when there are no UTM links" do
        visit utm_links_dashboard_path

        expect(page).to have_text("No links yet")
        expect(page).to have_text("Use UTM links to track which sources are driving the most conversions and revenue")
        expect(find("a", text: "Learn more about UTM tracking")[:href]).to include("/help/article/74-the-analytics-dashboard")
      end

      it "shows UTM links" do
        utm_link = create(:utm_link, seller:, unique_clicks: 3)
        create(:utm_link_driven_sale, utm_link:, purchase: create(:purchase, price_cents: 1000, seller:, link: create(:product, user: seller)))

        visit utm_links_dashboard_path

        wait_for_ajax
        expect(page).to have_table_row({ "Link" => utm_link.title, "Source" => utm_link.utm_source, "Medium" => utm_link.utm_medium, "Campaign" => utm_link.utm_campaign, "Destination" => "Profile page", "Clicks" => "3", "Revenue" => "$10", "Conversion" => "33.33%" })

        within find(:table_row, { "Link" => utm_link.title }) do
          copy_button = find_button("Copy link")
          copy_button.hover
          expect(copy_button).to have_tooltip(text: "Copy short link")
          copy_button.click
          expect(copy_button).to have_tooltip(text: "Copied!")
        end
      end

      describe "sidebar drawer" do
        let!(:utm_link) { create(:utm_link, seller:, utm_content: "video-ad", unique_clicks: 3) }
        let!(:utm_link_driven_sale) { create(:utm_link_driven_sale, utm_link:, purchase: create(:purchase, price_cents: 1000, seller:, link: create(:product, user: seller))) }
        let!(:utm_link_driven_sale2) { create(:utm_link_driven_sale, utm_link:, purchase: create(:purchase, price_cents: 1000, seller:, link: create(:product, user: seller))) }

        it "shows the selected UTM link details" do
          visit utm_links_dashboard_path

          wait_for_ajax
          find(:table_row, { "Link" => utm_link.title, "Clicks" => "3", "Sales" => "2", "Conversion" => "66.67%" }).click
          wait_for_ajax
          within_section utm_link.title, section_element: :aside do
            within_section "Details" do
              expect(page).to have_text("Destination Profile page", normalize_ws: true)
              expect(page).to have_link("Profile page", href: seller.profile_url)
              expect(page).to have_text("Source #{utm_link.utm_source}", normalize_ws: true)
              expect(page).to have_text("Medium #{utm_link.utm_medium}", normalize_ws: true)
              expect(page).to have_text("Campaign #{utm_link.utm_campaign}", normalize_ws: true)
              expect(page).to_not have_text("Term")
              expect(page).to have_text("Content video-ad", normalize_ws: true)
            end
            within_section "Statistics" do
              expect(page).to have_text("Clicks 3", normalize_ws: true)
              expect(page).to have_text("Sales 2", normalize_ws: true)
              expect(page).to have_text("Revenue $20", normalize_ws: true)
              expect(page).to have_text("Conversion rate 66.67%", normalize_ws: true)
            end
            within_section "Short link" do
              expect(page).to have_text(utm_link.short_url)
              copy_button = find_button("Copy short link")
              copy_button.hover
              expect(copy_button).to have_tooltip(text: "Copy short link")
            end
            within_section "UTM link" do
              expect(page).to have_text(utm_link.utm_url)
              copy_button = find_button("Copy UTM link")
              copy_button.hover
              expect(copy_button).to have_tooltip(text: "Copy UTM link")
            end

            expect(page).to have_link("Duplicate")
            expect(page).to have_link("Edit")
            expect(page).to have_button("Delete")
          end
        end

        it "allows deleting a UTM link" do
          visit utm_links_dashboard_path

          find(:table_row, { "Link" => utm_link.title }).click
          within_section utm_link.title, section_element: :aside do
            click_on "Delete"
          end
          within_modal "Delete link?" do
            click_on "Delete"
          end
          wait_for_ajax
          expect(page).to have_alert(text: "Link deleted!")
          expect(page).to_not have_section(utm_link.title, section_element: :aside)
          expect(page).to_not have_table_row({ "Link" => utm_link.title })
          expect(utm_link.reload).to be_deleted
        end
      end

      it "paginates the UTM links" do
        stub_const("PaginatedUtmLinksPresenter::PER_PAGE", 1)

        utm_link1 = create(:utm_link, seller:, created_at: 2.days.ago)
        utm_link2 = create(:utm_link, seller:, created_at: 1.day.ago)

        visit utm_links_dashboard_path

        expect(page).to have_table_row({ "Link" => utm_link2.title })
        expect(page).to_not have_table_row({ "Link" => utm_link1.title })
        expect(page).to have_button("1", aria: { current: "page" })
        expect(page).to have_button("2")
        expect(page).to_not have_button("3")
        expect(page).to have_button("Previous", disabled: true)
        expect(page).to have_button("Next")
        click_on "Next"
        expect(page).to have_table_row({ "Link" => utm_link1.title })
        expect(page).to_not have_table_row({ "Link" => utm_link2.title })
        expect(page).to have_button("2", aria: { current: "page" })
        expect(page).to have_button("1")
        expect(page).to_not have_button("3")
        expect(page).to have_button("Previous")
        expect(page).to have_button("Next", disabled: true)
        expect(page).to have_current_path(utm_links_dashboard_path({ page: 2 }))
      end

      it "sorts UTM links by different columns and direction and allows pagination" do
        stub_const("PaginatedUtmLinksPresenter::PER_PAGE", 1)

        utm_link1 = create(:utm_link, seller:, title: "A Link", utm_source: "twitter", utm_medium: "social",
                                      utm_campaign: "spring", unique_clicks: 3, created_at: 3.days.ago)
        utm_link2 = create(:utm_link, seller:, title: "B Link", utm_source: "newsletter", utm_medium: "email",
                                      utm_campaign: "winter", unique_clicks: 1, created_at: 1.day.ago)
        create(:utm_link_driven_sale, utm_link: utm_link1, purchase: create(:purchase, price_cents: 1000, seller:, link: create(:product, user: seller)))
        create(:utm_link_driven_sale, utm_link: utm_link1, purchase: create(:purchase, price_cents: 500, seller:, link: create(:product, user: seller)))
        create(:utm_link_driven_sale, utm_link: utm_link2, purchase: create(:purchase, price_cents: 2000, seller:, link: create(:product, user: seller)))

        visit utm_links_dashboard_path

        # By default, it sorts by "Date" column in descending order
        expect(page).to have_table_row({ "Link" => "B Link" })
        expect(page).to_not have_table_row({ "Link" => "A Link" })
        click_on "Next"
        expect(page).to have_table_row({ "Link" => "A Link" })
        expect(page).to_not have_table_row({ "Link" => "B Link" })

        # Sort by "Link" title
        find_and_click("th", text: "Link")
        expect(page).to have_current_path("#{utm_links_dashboard_path}?key=link&direction=asc")
        expect(page).to have_table_row({ "Link" => "A Link" })
        expect(page).to_not have_table_row({ "Link" => "B Link" })
        click_on "Next"
        expect(page).to have_current_path("#{utm_links_dashboard_path}?key=link&direction=asc&page=2")
        expect(page).to have_table_row({ "Link" => "B Link" })
        expect(page).to_not have_table_row({ "Link" => "A Link" })

        # Sort by "Source" column
        find_and_click("th", text: "Source")
        expect(page).to have_current_path("#{utm_links_dashboard_path}?key=source&direction=asc")
        expect(page).to have_table_row({ "Link" => "B Link", "Source" => "newsletter" })
        expect(page).to_not have_table_row({ "Link" => "A Link", "Source" => "twitter" })
        click_on "Next"
        expect(page).to have_current_path("#{utm_links_dashboard_path}?key=source&direction=asc&page=2")
        expect(page).to have_table_row({ "Link" => "A Link", "Source" => "twitter" })
        expect(page).to_not have_table_row({ "Link" => "B Link", "Source" => "newsletter" })

        # Sort by "Medium" column
        find_and_click("th", text: "Medium")
        expect(page).to have_current_path("#{utm_links_dashboard_path}?key=medium&direction=asc")
        expect(page).to have_table_row({ "Link" => "B Link", "Medium" => "email" })
        expect(page).to_not have_table_row({ "Link" => "A Link", "Medium" => "social" })
        click_on "Next"
        expect(page).to have_current_path("#{utm_links_dashboard_path}?key=medium&direction=asc&page=2")
        expect(page).to have_table_row({ "Link" => "A Link", "Medium" => "social" })
        expect(page).to_not have_table_row({ "Link" => "B Link", "Medium" => "email" })

        # Sort by "Campaign" column
        find_and_click("th", text: "Campaign")
        expect(page).to have_current_path("#{utm_links_dashboard_path}?key=campaign&direction=asc")
        expect(page).to have_table_row({ "Link" => "A Link", "Campaign" => "spring" })
        expect(page).to_not have_table_row({ "Link" => "B Link", "Campaign" => "winter" })
        click_on "Next"
        expect(page).to have_current_path("#{utm_links_dashboard_path}?key=campaign&direction=asc&page=2")
        expect(page).to have_table_row({ "Link" => "B Link", "Campaign" => "winter" })
        expect(page).to_not have_table_row({ "Link" => "A Link", "Campaign" => "spring" })

        # Sort by "Clicks" column
        find_and_click("th", text: "Clicks")
        expect(page).to have_current_path("#{utm_links_dashboard_path}?key=clicks&direction=asc")
        expect(page).to have_table_row({ "Link" => "B Link", "Clicks" => "1" })
        expect(page).to_not have_table_row({ "Link" => "A Link", "Clicks" => "3" })
        click_on "Next"
        expect(page).to have_current_path("#{utm_links_dashboard_path}?key=clicks&direction=asc&page=2")
        expect(page).to have_table_row({ "Link" => "A Link", "Clicks" => "3" })
        expect(page).to_not have_table_row({ "Link" => "B Link", "Clicks" => "1" })

        # Sort by "Revenue" column
        find_and_click("th", text: "Revenue")
        expect(page).to have_current_path("#{utm_links_dashboard_path}?key=revenue_cents&direction=asc")
        expect(page).to have_table_row({ "Link" => "A Link", "Revenue" => "$15" })
        expect(page).to_not have_table_row({ "Link" => "B Link", "Revenue" => "$20" })
        click_on "Next"
        expect(page).to have_current_path("#{utm_links_dashboard_path}?key=revenue_cents&direction=asc&page=2")
        expect(page).to have_table_row({ "Link" => "B Link", "Revenue" => "$20" })
        expect(page).to_not have_table_row({ "Link" => "A Link", "Revenue" => "$15" })

        # Sort by "Conversion" column
        find_and_click("th", text: "Conversion")
        expect(page).to have_current_path("#{utm_links_dashboard_path}?key=conversion_rate&direction=asc")
        expect(page).to have_table_row({ "Link" => "A Link", "Conversion" => "66.67%" })
        expect(page).to_not have_table_row({ "Link" => "B Link", "Conversion" => "100%" })
        click_on "Next"
        expect(page).to have_current_path("#{utm_links_dashboard_path}?key=conversion_rate&direction=asc&page=2")
        expect(page).to have_table_row({ "Link" => "B Link", "Conversion" => "100%" })
        expect(page).to_not have_table_row({ "Link" => "A Link", "Conversion" => "66.67%" })
      end

      it "filters UTM links by search query by adhering to the current column sort order" do
        stub_const("PaginatedUtmLinksPresenter::PER_PAGE", 1)

        utm_link1 = create(:utm_link, seller:,
                                      title: "Facebook Summer Sale",
                                      utm_source: "facebook",
                                      utm_medium: "social",
                                      utm_campaign: "summer_2024"
        )
        utm_link2 = create(:utm_link, seller:,
                                      title: "Twitter Winter Promo",
                                      utm_source: "twitter",
                                      utm_medium: "social",
                                      utm_campaign: "winter_2024"
        )

        visit utm_links_dashboard_path

        # Sort by "Link" column in descending order
        find_and_click("th", text: "Link")
        expect(page).to have_current_path("#{utm_links_dashboard_path}?key=link&direction=asc")
        find_and_click("th", text: "Link")
        expect(page).to have_current_path("#{utm_links_dashboard_path}?key=link&direction=desc")

        expect(page).to have_table_row({ "Link" => utm_link2.title })
        expect(page).to_not have_table_row({ "Link" => utm_link1.title })
        click_on "Next"
        expect(page).to have_table_row({ "Link" => utm_link1.title })
        expect(page).to_not have_table_row({ "Link" => utm_link2.title })
        expect(page).to have_current_path("#{utm_links_dashboard_path}?key=link&direction=desc&page=2")

        # Search by title
        select_disclosure "Search" do
          fill_in "Search", with: " Sale     "
        end
        wait_for_ajax
        expect(page).to have_table_row({ "Link" => utm_link1.title })
        expect(page).not_to have_table_row({ "Link" => utm_link2.title })
        expect(page).to_not have_button("Next")
        # Always takes to the first page when searching regardless of the previous page number
        expect(page).to have_current_path("#{utm_links_dashboard_path}?key=link&direction=desc&query=+Sale+++++")

        # Search by source
        select_disclosure "Search" do
          fill_in "Search", with: "TwiTTer"
        end
        wait_for_ajax
        expect(page).to have_table_row({ "Link" => utm_link2.title })
        expect(page).not_to have_table_row({ "Link" => utm_link1.title })
        expect(page).to_not have_button("Next")
        expect(page).to have_current_path("#{utm_links_dashboard_path}?key=link&direction=desc&query=TwiTTer")

        # Shows filtered results on accessing the page with the 'query' param
        visit "#{utm_links_dashboard_path}?key=source&direction=asc&query=PROMO"
        expect(page).to have_table_row({ "Link" => utm_link2.title })
        expect(page).not_to have_table_row({ "Link" => utm_link1.title })
        expect(page).to_not have_button("Next")

        # Search by medium
        select_disclosure "Search" do
          fill_in "Search", with: "Social"
        end
        wait_for_ajax
        expect(page).to have_table_row({ "Link" => utm_link1.title })
        expect(page).to_not have_table_row({ "Link" => utm_link2.title })
        click_on "Next"
        expect(page).to have_table_row({ "Link" => utm_link2.title })
        expect(page).to_not have_table_row({ "Link" => utm_link1.title })

        # Search by campaign
        select_disclosure "Search" do
          fill_in "Search", with: "winter_"
        end
        wait_for_ajax
        expect(page).to have_table_row({ "Link" => utm_link2.title })
        expect(page).to_not have_table_row({ "Link" => utm_link1.title })
        expect(page).to_not have_button("Next")

        # Search with no matches
        select_disclosure "Search" do
          fill_in "Search", with: "nonexistent"
        end
        wait_for_ajax
        expect(page).to have_text('No links found for "nonexistent"')
        expect(page).not_to have_table_row({ "Link" => utm_link1.title })
        expect(page).not_to have_table_row({ "Link" => utm_link2.title })
        expect(page).to_not have_button("Next")

        # Clear search
        select_disclosure "Search" do
          fill_in "Search", with: ""
        end
        wait_for_ajax
        expect(page).to have_table_row({ "Link" => utm_link1.title })
        expect(page).to_not have_table_row({ "Link" => utm_link2.title })
        click_on "Next"
        expect(page).to have_table_row({ "Link" => utm_link2.title })
        expect(page).to_not have_table_row({ "Link" => utm_link1.title })
      end

      it "allows deleting a UTM link" do
        stub_const("PaginatedUtmLinksPresenter::PER_PAGE", 1)

        utm_link1 = create(:utm_link, seller:)
        utm_link2 = create(:utm_link, seller:)

        visit utm_links_dashboard_path
        find_and_click("th", text: "Link")
        expect(page).to have_table_row({ "Link" => utm_link1.title })
        expect(page).to_not have_table_row({ "Link" => utm_link2.title })
        click_on "Next"
        expect(page).to have_table_row({ "Link" => utm_link2.title })
        expect(page).to_not have_table_row({ "Link" => utm_link1.title })
        within find(:table_row, { "Link" => utm_link2.title }) do
          select_disclosure "Open action menu"  do
            click_on "Delete"
          end
        end
        within_modal "Delete link?" do
          expect(page).to have_text(%Q(Are you sure you want to delete the link "#{utm_link2.title}"? This action cannot be undone.))
          click_on "Cancel"
        end
        expect(page).to_not have_modal("Delete link?")
        expect(page).to have_table_row({ "Link" => utm_link2.title })
        within find(:table_row, { "Link" => utm_link2.title }) do
          select_disclosure "Open action menu"  do
            click_on "Delete"
          end
        end
        within_modal "Delete link?" do
          click_on "Delete"
        end
        wait_for_ajax
        expect(page).to have_alert(text: "Link deleted!")
        expect(page).to_not have_button("Next")
        expect(page).to_not have_table_row({ "Link" => utm_link2.title })
        expect(page).to have_table_row({ "Link" => utm_link1.title })
        expect(utm_link2.reload).to be_deleted
      end
    end

    describe "create page" do
      let!(:product) { create(:product, user: seller, name: "Product A") }
      let!(:post) { create(:audience_post, :published, seller:, name: "Post B", shown_on_profile: true) }
      let!(:existing_utm_link) do
        create(:utm_link, seller:,
                          utm_campaign: "spring",
                          utm_medium: "social",
                          utm_source: "facebook",
                          utm_term: "sale",
                          utm_content: "banner"
        )
      end

      it "renders the create link form" do
        allow(SecureRandom).to receive(:alphanumeric).and_return("unique01")

        visit "#{utm_links_dashboard_path}/new"

        expect(page).to have_text("Create link")
        expect(page).to have_link("Cancel", href: utm_links_dashboard_path)
        expect(page).to have_text("Create UTM links to track where your traffic is coming from")
        expect(page).to have_text("Once set up, simply share the links to see which sources are driving more conversions and revenue")
        expect(find("a", text: "Learn more")[:href]).to include("/help/article/74-the-analytics-dashboard")

        expect(page).to have_input_labelled("Title", with: "")
        find(:label, "Destination").click
        expect(page).to have_combo_box("Destination", options: ["Profile page", "Subscribe page", "Product — Product A", "Post — Post B"])
        expect(page).to have_input_labelled("Link", with: "unique01")
        send_keys(:escape)
        find(:label, "Source").click
        expect(page).to have_combo_box("Source", options: ["facebook"])
        send_keys(:escape)
        find(:label, "Medium").click
        expect(page).to have_combo_box("Medium", options: ["social"])
        send_keys(:escape)
        find(:label, "Campaign").click
        expect(page).to have_combo_box("Campaign", options: ["spring"])
        send_keys(:escape)
        find(:label, "Term").click
        expect(page).to have_combo_box("Term", options: ["sale"])
        send_keys(:escape)
        find(:label, "Content").click
        expect(page).to have_combo_box("Content", options: ["banner"])
        send_keys(:escape)

        expect(page).to_not have_field("Generated URL with UTM tags")

        find(:label, "Destination").click
        select_combo_box_option "Profile page", from: "Destination"
        expect(page).to_not have_field("Generated URL with UTM tags")

        find(:label, "Source").click
        select_combo_box_option "facebook", from: "Source"
        select_combo_box_option "social", from: "Medium"
        select_combo_box_option "spring", from: "Campaign"
        select_combo_box_option "sale", from: "Term"
        select_combo_box_option "banner", from: "Content"

        expect(page).to have_field("Generated URL with UTM tags", with: "#{seller.profile_url}?utm_source=facebook&utm_medium=social&utm_campaign=spring&utm_term=sale&utm_content=banner", readonly: true)

        find(:label, "Destination").click
        select_combo_box_option "Post — Post B", from: "Destination"
        expect(page).to have_field("Generated URL with UTM tags", with: "#{post.full_url}?utm_source=facebook&utm_medium=social&utm_campaign=spring&utm_term=sale&utm_content=banner", readonly: true)

        find(:label, "Destination").click
        select_combo_box_option "Subscribe page", from: "Destination"
        expect(page).to have_field("Generated URL with UTM tags", with: "#{Rails.application.routes.url_helpers.custom_domain_subscribe_url(host: seller.subdomain_with_protocol)}?utm_source=facebook&utm_medium=social&utm_campaign=spring&utm_term=sale&utm_content=banner", readonly: true)

        find(:label, "Destination").click
        select_combo_box_option "Product — Product A", from: "Destination"
        expect(page).to have_field("Generated URL with UTM tags", with: "#{product.long_url}?utm_source=facebook&utm_medium=social&utm_campaign=spring&utm_term=sale&utm_content=banner", readonly: true)

        # An arbitrary value can be entered in a UTM field, and it will be transformed into a valid value
        find(:label, "Term").click
        fill_in "Term", with: "BIG Offer!"
        within :fieldset, "Term" do
          find_and_click("[role='option']", text: "big-offer-")
        end
        find(:label, "Content").click
        fill_in "Content", with: "a" * 250
        within :fieldset, "Content" do
          find_and_click("[role='option']", text: "a" * 200)
        end
        expect(page).to have_field("Generated URL with UTM tags", with: "#{product.long_url}?utm_source=facebook&utm_medium=social&utm_campaign=spring&utm_term=big-offer-&utm_content=#{'a' * 200}", readonly: true)
      end

      it "generates a new permalink when clicking the refresh button" do
        allow(SecureRandom).to receive(:alphanumeric).and_return("initial1", "newlink2")
        visit "#{utm_links_dashboard_path}/new"

        within :fieldset, "Link" do
          expect(page).to have_text(%Q(#{UrlService.short_domain_with_protocol.sub("#{PROTOCOL}://", '')}/u/))
          expect(page).to have_field("Link", with: "initial1", readonly: true)
          click_on "Generate new short link"
          wait_for_ajax
          expect(page).to have_field("Link", with: "newlink2", readonly: true)
        end
      end

      it "shows validation errors" do
        record = UtmLink.new(seller:, title: "Test Link", target_resource_type: "profile_page", permalink: "$tesT123")
        record.valid?
        allow_any_instance_of(SaveUtmLinkService).to receive(:perform).and_raise(ActiveRecord::RecordInvalid.new(record))

        visit "#{utm_links_dashboard_path}/new"

        click_on "Add link"
        expect(find_field("Title")).to have_ancestor("fieldset.danger")
        within :fieldset, "Title" do
          expect(page).to have_text("Must be present")
        end
        fill_in "Title", with: "Test Link"
        expect(find_field("Title")).to_not have_ancestor("fieldset.danger")
        expect(page).to_not have_text("Must be present")

        click_on "Add link"
        expect(find_field("Destination")).to have_ancestor("fieldset.danger")
        within :fieldset, "Destination" do
          expect(page).to have_text("Must be present")
        end
        select_combo_box_option "Product — Product A", from: "Destination"
        expect(page).to_not have_text("Must be present")

        click_on "Add link"
        expect(find_field("Source")).to have_ancestor("fieldset.danger")
        within :fieldset, "Source" do
          expect(page).to have_text("Must be present")
        end
        select_combo_box_option "facebook", from: "Source"
        expect(page).to_not have_text("Must be present")

        click_on "Add link"
        expect(find_field("Medium")).to have_ancestor("fieldset.danger")
        within :fieldset, "Medium" do
          expect(page).to have_text("Must be present")
        end
        select_combo_box_option "social", from: "Medium"
        expect(page).to_not have_text("Must be present")

        click_on "Add link"
        expect(find_field("Campaign")).to have_ancestor("fieldset.danger")
        within :fieldset, "Campaign" do
          expect(page).to have_text("Must be present")
        end
        select_combo_box_option "spring", from: "Campaign"
        expect(page).to_not have_text("Must be present")

        click_on "Add link"
        wait_for_ajax
        expect(find_field("Link")).to have_ancestor("fieldset.danger")
        within :fieldset, "Link" do
          expect(page).to have_text("is invalid")
        end
        expect(page).to_not have_alert(text: "Link created!")
        expect(page).to have_current_path("#{utm_links_dashboard_path}/new")
      end

      it "creates a UTM link" do
        visit "#{utm_links_dashboard_path}/new"

        fill_in "Title", with: "Test Link"
        expect(page).to_not have_field("Generated URL with UTM tags")
        select_combo_box_option "Product — Product A", from: "Destination"
        within :fieldset, "Link" do
          button = find_button("Copy short link")
          button.hover
          expect(button).to have_tooltip(text: "Copy short link")
        end
        expect(page).to_not have_field("Generated URL with UTM tags")
        select_combo_box_option "facebook", from: "Source"
        expect(page).to_not have_field("Generated URL with UTM tags")
        select_combo_box_option "social", from: "Medium"
        expect(page).to_not have_field("Generated URL with UTM tags")
        select_combo_box_option "spring", from: "Campaign"
        expect(page).to have_field("Generated URL with UTM tags", with: "#{product.long_url}?utm_source=facebook&utm_medium=social&utm_campaign=spring")
        select_combo_box_option "sale-2", from: "Term"
        select_combo_box_option "banner", from: "Content"
        expect(page).to have_field("Generated URL with UTM tags", with: "#{product.long_url}?utm_source=facebook&utm_medium=social&utm_campaign=spring&utm_term=sale-2&utm_content=banner")
        within :fieldset, "Generated URL with UTM tags" do
          button = find_button("Copy UTM link")
          button.hover
          expect(button).to have_tooltip(text: "Copy UTM link")
        end

        click_on "Add link"
        wait_for_ajax

        expect(page).to have_alert(text: "Link created!")
        expect(page).to have_current_path(utm_links_dashboard_path)

        expect(page).to have_table_row({ "Link" => "Test Link", "Source" => "facebook", "Medium" => "social", "Campaign" => "spring", "Destination" => "Product A" })

        utm_link = seller.utm_links.last
        expect(utm_link.title).to eq("Test Link")
        expect(utm_link.target_resource_type).to eq("product_page")
        expect(utm_link.target_resource_id).to eq(product.id)
        expect(utm_link.utm_source).to eq("facebook")
        expect(utm_link.utm_medium).to eq("social")
        expect(utm_link.utm_campaign).to eq("spring")
        expect(utm_link.utm_term).to eq("sale-2")
        expect(utm_link.utm_content).to eq("banner")
      end
    end

    describe "duplicate link" do
      it "pre-fills the create page with the existing UTM link's values" do
        product = create(:product, user: seller, name: "Product A")
        existing_utm_link = create(:utm_link, seller:, title: "Existing UTM Link", target_resource_type: :product_page, target_resource_id: product.id, utm_source: "newsletter", utm_medium: "email", utm_campaign: "summer-sale", utm_term: "sale", utm_content: "banner")
        visit utm_links_dashboard_path

        within(:table_row, { "Link" => "Existing UTM Link" }) do
          select_disclosure "Open action menu"  do
            click_on "Duplicate"
          end
        end

        expect(page).to have_current_path("#{utm_links_dashboard_path}/new?copy_from=#{existing_utm_link.external_id}")
        expect(page).to have_input_labelled("Title", with: "Existing UTM Link (copy)")
        within :fieldset, "Destination" do
          expect(page).to have_text("Product — Product A")
        end
        expect(page).to_not have_input_labelled("Link", with: existing_utm_link.permalink)
        within :fieldset, "Source" do
          expect(page).to have_text("newsletter")
        end
        within :fieldset, "Medium" do
          expect(page).to have_text("email")
        end
        within :fieldset, "Campaign" do
          expect(page).to have_text("summer-sale")
        end
        within :fieldset, "Term" do
          expect(page).to have_text("sale")
        end
        within :fieldset, "Content" do
          expect(page).to have_text("banner")
        end
        expect(page).to have_field("Generated URL with UTM tags", with: "#{product.long_url}?utm_source=newsletter&utm_medium=email&utm_campaign=summer-sale&utm_term=sale&utm_content=banner")

        click_on "Add link"
        wait_for_ajax

        within :fieldset, "Destination" do
          expect(page).to have_text("A link with similar UTM parameters already exists for this destination!")
        end
        expect(page).to have_current_path("#{utm_links_dashboard_path}/new?copy_from=#{existing_utm_link.external_id}")
        expect(UtmLink.sole).to eq(existing_utm_link)

        # Update a UTM parameter with a different value
        find(:label, "Campaign").click
        fill_in "Campaign", with: "summer-sale-2"
        within :fieldset, "Campaign" do
          find_and_click("[role='option']", text: "summer-sale-2")
        end
        click_on "Add link"
        wait_for_ajax
        expect(page).to have_alert(text: "Link created!")
        expect(page).to have_current_path(utm_links_dashboard_path)
        expect(page).to have_table_row({ "Link" => "Existing UTM Link (copy)", "Source" => "newsletter", "Medium" => "email", "Campaign" => "summer-sale-2" })
        expect(UtmLink.pluck(:title)).to eq(["Existing UTM Link", "Existing UTM Link (copy)"])
        expect(UtmLink.last.permalink).to_not eq(existing_utm_link.permalink)
      end
    end

    describe "update page" do
      it "performs validations and updates the UTM link" do
        utm_link = create(:utm_link, seller:, utm_campaign: "summer-sale-1")
        old_permalink = utm_link.permalink

        visit utm_links_dashboard_path
        within(:table_row, { "Link" => utm_link.title }) do
          select_disclosure "Open action menu"  do
            click_on "Edit"
          end
        end

        expect(page).to have_current_path("#{utm_links_dashboard_path}/#{utm_link.external_id}/edit")
        expect(page).to have_text("Edit link")
        expect(page).to have_link("Cancel", href: utm_links_dashboard_path)
        expect(find("a", text: "Learn more")["href"]).to include("/help/")

        # Check that the form is pre-filled with the existing UTM link's values
        expect(page).to have_input_labelled("Title", with: utm_link.title)
        within :fieldset, "Destination" do
          expect(page).to have_text("Profile page")
        end
        expect(page).to have_field("Link", with: old_permalink, disabled: true)
        within :fieldset, "Link" do
          expect(page).to have_text(%Q(#{UrlService.short_domain_with_protocol.sub("#{PROTOCOL}://", '')}/u/))
          button = find_button("Copy short link")
          button.hover
          expect(button).to have_tooltip(text: "Copy short link")
        end
        within :fieldset, "Source" do
          expect(page).to have_text("twitter")
        end
        within :fieldset, "Medium" do
          expect(page).to have_text("social")
        end
        within :fieldset, "Campaign" do
          expect(page).to have_text("summer-sale-1")
        end
        find(:label, "Term").click
        expect(page).to have_combo_box("Term", options: ["Enter something"])
        send_keys(:escape)
        find(:label, "Content").click
        expect(page).to have_combo_box("Content", options: ["Enter something"])

        expect(page).to have_field("Generated URL with UTM tags", with: "#{seller.profile_url}?utm_source=twitter&utm_medium=social&utm_campaign=summer-sale-1")
        within :fieldset, "Generated URL with UTM tags" do
          button = find_button("Copy UTM link")
          button.hover
          expect(button).to have_tooltip(text: "Copy UTM link")
        end

        # Update field values
        fill_in "Title", with: "Updated UTM Link"
        find(:label, "Source").click
        fill_in "Source", with: "INSTAgram"
        within :fieldset, "Source" do
          find_and_click("[role='option']", text: "instagram")
        end
        send_keys(:tab)
        find(:label, "Content").click
        fill_in "Content", with: "Hello World!"
        within :fieldset, "Content" do
          find_and_click("[role='option']", text: "hello-world-")
        end

        expect(page).to have_field("Generated URL with UTM tags", with: "#{seller.profile_url}?utm_source=instagram&utm_medium=social&utm_campaign=summer-sale-1&utm_content=hello-world-")

        # Clear a required value
        within :fieldset, "Campaign" do
          click_on "Clear value"
        end

        # Test validation errors
        click_on "Save changes"
        expect(find_field("Campaign")).to have_ancestor("fieldset.danger")
        within :fieldset, "Campaign" do
          expect(page).to have_text("Must be present")
        end
        select_combo_box_option "summer-sale-1", from: "Campaign"
        expect(page).to_not have_text("Must be present")

        # Save the changes and check that the link was updated on the listing page
        click_on "Save changes"
        wait_for_ajax
        expect(page).to have_alert(text: "Link updated!")
        expect(page).to have_current_path(utm_links_dashboard_path)
        find(:table_row, { "Link" => "Updated UTM Link", "Source" => "instagram", "Medium" => "social", "Campaign" => "summer-sale-1" }).click
        within_section "Updated UTM Link", section_element: :aside do
          within_section "Details" do
            expect(page).to have_text("Source instagram", normalize_ws: true)
            expect(page).to have_text("Content hello-world-", normalize_ws: true)
          end
          within_section "Short link" do
            expect(page).to have_text(old_permalink)
          end
          within_section "UTM link" do
            expect(page).to have_text("utm_source=instagram")
            expect(page).to have_text("utm_medium=social")
            expect(page).to have_text("utm_campaign=summer-sale-1")
            expect(page).to have_text("utm_content=hello-world-")
          end
        end

        utm_link.reload
        expect(utm_link.title).to eq("Updated UTM Link")
        expect(utm_link.target_resource_id).to be_nil
        expect(utm_link.target_resource_type).to eq("profile_page")
        expect(utm_link.permalink).to eq(old_permalink)
        expect(utm_link.utm_source).to eq("instagram")
        expect(utm_link.utm_medium).to eq("social")
        expect(utm_link.utm_campaign).to eq("summer-sale-1")
        expect(utm_link.utm_term).to be_nil
        expect(utm_link.utm_content).to eq("hello-world-")
      end
    end
  end

  describe "sale attribution", :sidekiq_inline do
    it "attributes a purchase to a UTM link when buyer visits through the short URL" do
      product = create(:product, user: seller, price_cents: 1000)
      utm_link = create(:utm_link, seller:, target_resource_type: :product_page, target_resource_id: product.id)

      visit utm_link.short_url
      expect(page.current_url).to eq(utm_link.utm_url)
      add_to_cart(product)
      check_out(product)

      purchase = Purchase.last
      driven_sale = utm_link.utm_link_driven_sales.sole
      expect(driven_sale.purchase_id).to eq(purchase.id)
      expect(driven_sale.utm_link_visit.id).to eq(utm_link.utm_link_visits.last.id)
      expect(driven_sale.utm_link_visit.browser_guid).to eq(purchase.browser_guid)

      login_as(seller)

      visit utm_links_dashboard_path
      wait_for_ajax
      find(:table_row, { "Link" => utm_link.title, "Clicks" => "1", "Revenue" => "$10", "Conversion" => "100%" }).click
      within_section "Statistics" do
        expect(page).to have_text("Clicks 1", normalize_ws: true)
        expect(page).to have_text("Sales 1", normalize_ws: true)
        expect(page).to have_text("Revenue $10", normalize_ws: true)
        expect(page).to have_text("Conversion rate 100%", normalize_ws: true)
      end
    end

    it "attributes a purchase to a UTM link when buyer visits through the UTM URL" do
      product = create(:product, user: seller)
      utm_link = create(:utm_link, seller:, target_resource_type: :product_page, target_resource_id: product.id)

      visit utm_link.utm_url
      expect(page.current_url).to eq(utm_link.utm_url)
      add_to_cart(product)
      check_out(product)

      purchase = Purchase.last
      driven_sale = utm_link.utm_link_driven_sales.sole
      expect(driven_sale.purchase_id).to eq(purchase.id)
      expect(driven_sale.utm_link_visit.id).to eq(utm_link.utm_link_visits.last.id)
      expect(driven_sale.utm_link_visit.browser_guid).to eq(purchase.browser_guid)
    end

    it "attributes a purchase to the latest visit which is within the attribution window" do
      product = create(:product, user: seller)
      utm_link = create(:utm_link, seller:, target_resource_type: :product_page, target_resource_id: product.id)

      visit utm_link.short_url
      expect(page.current_url).to eq(utm_link.utm_url)
      old_visit = utm_link.utm_link_visits.last
      old_visit.update!(created_at: 8.days.ago)

      visit "/"
      visit utm_link.short_url
      latest_visit = utm_link.utm_link_visits.last
      latest_visit.update!(created_at: 6.days.ago)

      add_to_cart(product)
      check_out(product)

      purchase = Purchase.last
      driven_sale = utm_link.reload.utm_link_driven_sales.sole
      expect(driven_sale.purchase_id).to eq(purchase.id)
      expect(driven_sale.utm_link_visit.id).to eq(latest_visit.id)
      expect(driven_sale.utm_link_visit.browser_guid).to eq(purchase.browser_guid)
      expect(old_visit.utm_link_driven_sales.count).to eq(0)
      expect(utm_link.total_clicks).to eq(2)
      expect(utm_link.unique_clicks).to eq(1)
    end

    it "does not attribute a purchase to a UTM link when the latest visit is outside the attribution window" do
      product = create(:product, user: seller)
      utm_link = create(:utm_link, seller:, target_resource_type: :product_page, target_resource_id: product.id)

      visit utm_link.short_url
      utm_link.utm_link_visits.last.update!(created_at: 8.days.ago)
      add_to_cart(product)
      check_out(product)

      expect(utm_link.utm_link_driven_sales.count).to eq(0)
    end

    it "does not attribute a purchase when there is no matching UTM link visit" do
      product1 = create(:product, user: seller)
      product2 = create(:product, user: seller)
      utm_link = create(:utm_link, seller:, target_resource_type: :product_page, target_resource_id: product1.id)

      visit utm_link.short_url
      visit product2.long_url
      add_to_cart(product2)
      check_out(product2)

      expect(utm_link.utm_link_driven_sales.count).to eq(0)
      expect(utm_link.reload.unique_clicks).to eq(1)
    end

    it "attributes all qualified purchases to respective UTM link visits when buying multiple products", :elasticsearch_wait_for_refresh do
      seller2 = create(:user)
      Feature.activate_user(:utm_links, seller2)

      product1 = create(:product, name: "Product 1 by Seller 1", user: seller)
      product2 = create(:product, name: "Product 2 by Seller 1", user: seller)
      product1_by_seller2 = create(:product, name: "Product 1 by Seller 2", user: seller2)
      product2_by_seller2 = create(:product, name: "Product 2 by Seller 2", user: seller2)

      seller1_utm_link = create(:utm_link, seller:, target_resource_type: :profile_page)
      seller2_utm_link = create(:utm_link, seller: seller2, target_resource_type: :product_page, target_resource_id: product1_by_seller2.id)

      seller1_section = create(:seller_profile_products_section, seller:, header: "Products", shown_products: [product1.id, product2.id])
      create(:seller_profile, seller:, json_data: { tabs: [{ name: "Tab", sections: [seller1_section.id] }] })
      seller2_section = create(:seller_profile_products_section, seller: seller2, header: "Products", shown_products: [product1_by_seller2.id, product2_by_seller2.id])
      create(:seller_profile, seller: seller2, json_data: { tabs: [{ name: "Tab", sections: [seller2_section.id] }] })

      visit seller1_utm_link.short_url
      wait_for_ajax
      seller1_utm_link_visit = seller1_utm_link.utm_link_visits.last
      click_on "Product 1 by Seller 1"
      click_on "Add to cart"
      visit product2.long_url
      add_to_cart(product2)

      visit seller2_utm_link.short_url
      seller2_utm_link_visit = seller2_utm_link.utm_link_visits.last
      add_to_cart(product1_by_seller2)
      visit product2_by_seller2.long_url
      add_to_cart(product2_by_seller2)

      check_out(product1)

      purchases = Order.last.purchases.successful
      expect(purchases.pluck(:link_id)).to match_array([product1.id, product2.id, product1_by_seller2.id, product2_by_seller2.id])
      expect(UtmLinkDrivenSale.count).to eq(3)

      seller1_driven_sales = seller1_utm_link.utm_link_driven_sales
      expect(seller1_driven_sales.count).to eq(2)
      expect(seller1_driven_sales.pluck(:utm_link_visit_id)).to match_array([seller1_utm_link_visit.id, seller1_utm_link_visit.id])
      expect(seller1_driven_sales.pluck(:purchase_id)).to match_array(purchases.where(link_id: [product1.id, product2.id]).pluck(:id))

      seller2_driven_sales = seller2_utm_link.utm_link_driven_sales
      expect(seller2_driven_sales.sole.utm_link_visit_id).to eq(seller2_utm_link_visit.id)
      expect(seller2_driven_sales.sole.purchase_id).to eq(purchases.find_by!(link_id: product1_by_seller2.id).id)
    end
  end

  it "auto-creates a new UTM link and records a visit if the UTM link doesn't exist", :sidekiq_inline do
    product = create(:product, user: seller, name: "My Product")

    expect(UtmLink.count).to eq(0)

    expect do
      visit product.long_url + "?utm_source=instagram&utm_medium=social&utm_campaign=Flash%20Sale&utm_content=reel&utm_term=Sale"
    end.to change(UtmLink, :count).by(1)
      .and change(UtmLinkVisit, :count).from(0).to(1)

    utm_link = UtmLink.last
    expect(utm_link.title).to eq("Product — My Product (auto-generated)")
    expect(utm_link.utm_source).to eq("instagram")
    expect(utm_link.utm_medium).to eq("social")
    expect(utm_link.utm_campaign).to eq("flash-sale")
    expect(utm_link.utm_content).to eq("reel")
    expect(utm_link.utm_term).to eq("sale")
    expect(utm_link.seller).to eq(seller)
    expect(utm_link.target_resource_type).to eq("product_page")
    expect(utm_link.target_resource_id).to eq(product.id)
    expect(utm_link.total_clicks).to eq(1)
    expect(utm_link.unique_clicks).to eq(1)

    expect do
      expect do
        refresh
      end.not_to change(UtmLink, :count)
    end.to change(UtmLinkVisit, :count).from(1).to(2)

    utm_link.reload
    expect(utm_link.total_clicks).to eq(2)
    expect(utm_link.unique_clicks).to eq(1)
  end

  it "recognizes links with the same UTM parameters for different target resources" do
    product = create(:product, user: seller)
    post = create(:audience_post, :published, seller:, shown_on_profile: true)
    product_utm_link = create(:utm_link, utm_source: "source", utm_medium: "medium", utm_campaign: "campaign", utm_content: "content", utm_term: "term", seller:, target_resource_type: :product_page, target_resource_id: product.id)
    post_utm_link = create(:utm_link, utm_source: "source", utm_medium: "medium", utm_campaign: "campaign", utm_content: "content", utm_term: "term", seller:, target_resource_type: :post_page, target_resource_id: post.id)

    expect do
      expect do
        visit product_utm_link.short_url
      end.to change { product_utm_link.reload.utm_link_visits.count }.by(1)
    end.not_to change { post_utm_link.reload.utm_link_visits.count }

    expect do
      expect do
        visit post_utm_link.short_url
      end.to change { post_utm_link.reload.utm_link_visits.count }.by(1)
    end.not_to change { product_utm_link.reload.utm_link_visits.count }

    expect do
      expect do
        expect do
          visit seller.profile_url + "?utm_source=source&utm_medium=medium&utm_campaign=campaign&utm_content=content&utm_term=term"
        end.to change { UtmLink.count }.by(1)
           .and change { UtmLinkVisit.count }.by(1)
      end.not_to change { product_utm_link.reload.utm_link_visits.count }
    end.not_to change { post_utm_link.reload.utm_link_visits.count }
  end
end
