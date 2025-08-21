# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Email List", :js, :sidekiq_inline, :elasticsearch_wait_for_refresh, type: :system) do
  before do
    allow_any_instance_of(Iffy::Post::IngestService).to receive(:perform).and_return(true)
  end

  describe "emails" do
    let(:seller) { create(:named_seller, timezone: "UTC") }
    let(:buyer) { create(:user) }
    let(:product) { create(:product, user: seller, name: "Product name") }
    let!(:purchase) { create(:purchase, link: product, purchaser: buyer) }

    let!(:installment1) { create(:installment, link: product, name: "Email 1 (sent)", message: "test", published_at: 2.days.ago) }
    let!(:installment2) { create(:installment, link: product, name: "Email 2 (draft)", message: "test", created_at: 1.hour.ago) }
    let!(:installment3) { create(:installment, link: product, name: "Email 3 (sent)", message: "test", shown_on_profile: true, published_at: 3.days.ago) }
    let!(:installment4) { create(:installment, link: product, name: "Email 4 (draft)", message: "test", created_at: 5.hour.ago, updated_at: 5.hour.ago) }
    let!(:installment5) { create(:scheduled_installment, link: product, name: "Email 5 (scheduled)", message: "test", created_at: 5.hour.ago) }
    let!(:installment6) { create(:scheduled_installment, link: product, name: "Email 6 (scheduled)", message: "test", created_at: 1.hour.ago) }

    include_context "with switching account to user as admin for seller"

    before do
      recreate_model_indices(Purchase)
    end

    describe "published emails" do
      it "shows published emails" do
        expect_any_instance_of(Installment).to receive(:send_preview_email).with(user_with_role_for_seller)

        CreatorEmailOpenEvent.create!(installment_id: installment1.id)

        url1 = "example.com"
        url2 = "example.com/this-is-a-very-very-long-url-12345-the-quick-brown-fox-jumps-over-the-lazy-dog"
        CreatorEmailClickSummary.create!(installment_id: installment1.id, total_unique_clicks: 123, urls: { url1 => 100, url2 => 23 })
        installment1.increment_total_delivered

        visit "#{emails_path}/published"

        within_table "Published" do
          expect(page).to have_table_row({ "Subject" => "Email 1 (sent)", "Emailed" => "1", "Opened" => "100%", "Clicks" => "123", "Views" => "n/a" })
          cell = page.find("td[data-label='Clicks'] > [aria-describedby]", text: "123")
          expect(cell).to have_tooltip(text: url1, visible: false)
          expect(cell).to have_tooltip(text: url2.truncate(70), visible: false)
          expect(page).to have_table_row({ "Subject" => "Email 3 (sent)", "Emailed" => "--", "Opened" => "--", "Clicks" => "0", "Views" => "0" })
          expect(page).to_not have_table_row({ "Subject" => "Email 2 (draft)" })
          expect(page).to_not have_table_row({ "Subject" => "Email 4 (draft)" })
          expect(page).to_not have_table_row({ "Subject" => "Email 5 (scheduled)" })
          expect(page).to_not have_table_row({ "Subject" => "Email 6 (scheduled)" })
        end

        # Opens a sidebar drawer with additional information of the selected email
        find(:table_row, { name: "Email 1 (sent)" }).click
        within_section "Email 1 (sent)", section_element: :aside do
          expect(page).to have_text("Sent #{installment1.published_at.in_time_zone(seller.timezone).strftime("%-m/%-d/%Y, %-I:%M:%S %p")}", normalize_ws: true)
          expect(page).to have_text("Emailed 1", normalize_ws: true)
          expect(page).to have_text("Opened 1 (100%)", normalize_ws: true)
          expect(page).to have_text("Clicks 123 (12,300%)", normalize_ws: true)
          expect(page).to have_text("Views n/a", normalize_ws: true)
          expect(page).to have_link("Duplicate")
          expect(page).to have_link("Edit")
          expect(page).to have_button("Delete")
          expect(page).to_not have_link("View post")

          # Allows sending the email preview for the email that was created with "Send email" channel
          click_on "View email"
        end
        wait_for_ajax
        expect(page).to have_alert(text: "A preview has been sent to your email.")

        # Allows closing the sidebar drawer
        within_section "Email 1 (sent)", section_element: :aside do
          click_on "Close"
        end
        expect(page).to_not have_section("Email 1 (sent)", section_element: :aside)

        find(:table_row, { name: "Email 3 (sent)" }).click
        within_section "Email 3 (sent)", section_element: :aside do
          expect(page).to have_text("Sent #{installment3.published_at.in_time_zone(seller.timezone).strftime("%-m/%-d/%Y, %-I:%M:%S %p")}", normalize_ws: true)
          expect(page).to have_text("Emailed --", normalize_ws: true)
          expect(page).to have_text("Opened --", normalize_ws: true)
          expect(page).to have_text("Clicks --", normalize_ws: true)
          expect(page).to have_text("Views 0", normalize_ws: true)
          expect(page).to have_link("Duplicate")
          expect(page).to have_link("Edit")
          expect(page).to have_button("Delete")
          expect(page).to have_button("View email")

          # Allows previwing the post in a window for the email that was created with "Shown on profile" channel
          new_window = window_opened_by { click_on "View post" }
          within_window new_window do
            expect(page).to have_text("Email 3 (sent)")
          end

          click_on "Close"
        end

        # Ensures that the "Views" count is incremented when a buyer views the post
        Capybara.using_session(:buyer_session) do
          login_as buyer
          visit custom_domain_view_post_url(host: seller.subdomain_with_protocol, slug: installment3.slug)
          wait_for_ajax
        end
        refresh
        expect(page).to have_table_row({ "Subject" => "Email 3 (sent)", "Emailed" => "--", "Opened" => "--", "Clicks" => "0", "Views" => "1" })
      end

      it "loads more emails" do
        stub_const("PaginatedInstallmentsPresenter::PER_PAGE", 2)

        visit "#{emails_path}/published"
        wait_for_ajax

        expect(page).to have_table_row({ "Subject" => "Email 1 (sent)" })
        expect(page).to have_table_row({ "Subject" => "Email 3 (sent)" })

        expect(page).to_not have_button("Load more")

        create(:installment, name: "Hello world!", seller:, link: product, published_at: 10.days.ago)
        refresh

        expect(page).to have_table_row({ "Subject" => "Email 1 (sent)" })
        expect(page).to have_table_row({ "Subject" => "Email 3 (sent)" })
        expect(page).to_not have_table_row({ "Subject" => "Hello world!" })

        click_on "Load more"
        wait_for_ajax

        expect(page).to have_table_row({ "Subject" => "Email 1 (sent)" })
        expect(page).to have_table_row({ "Subject" => "Email 3 (sent)" })
        expect(page).to have_table_row({ "Subject" => "Hello world!" })

        expect(page).to_not have_button("Load more")
      end

      it "deletes an email" do
        visit "#{emails_path}/published"

        find(:table_row, { name: "Email 1 (sent)" }).click
        within_section "Email 1 (sent)", section_element: :aside do
          click_on "Delete"
        end

        within_modal "Delete email?" do
          expect(page).to have_text("Are you sure you want to delete the email \"Email 1 (sent)\"? Customers who had access will no longer be able to see it. This action cannot be undone.")
          click_on "Delete email"
        end
        wait_for_ajax
        expect(page).to have_alert(text: "Email deleted!")

        expect(page).to_not have_table_row({ "Subject" => "Email 1 (sent)" })

        expect(installment1.reload.deleted_at).to_not be_nil
      end
    end

    describe "scheduled emails" do
      it "shows scheduled emails" do
        installment7 = create(:scheduled_installment, seller:, name: "Email 7 (scheduled)", message: "test", link: nil, installment_type: Installment::AUDIENCE_TYPE, created_at: 1.hour.ago)
        installment7.installment_rule.update!(to_be_published_at: 1.day.from_now)

        visit "#{emails_path}/scheduled"
        wait_for_ajax

        within_table "Scheduled for #{installment5.installment_rule.to_be_published_at.in_time_zone(seller.timezone).strftime("%b %-d, %Y")}" do
          expect(page).to have_table_row({ "Subject" => "Email 5 (scheduled)", "Sent to" => "Customers of Product name", "Audience" => "1" })
          expect(page).to have_table_row({ "Subject" => "Email 6 (scheduled)", "Sent to" => "Customers of Product name", "Audience" => "1" })
        end
        within_table "Scheduled for #{installment7.installment_rule.to_be_published_at.in_time_zone(seller.timezone).strftime("%b %-d, %Y")}" do
          expect(page).to have_table_row({ "Subject" => "Email 7 (scheduled)", "Sent to" => "Your customers and followers", "Audience" => "1" })
        end
        expect(page).to_not have_table_row({ "Subject" => "Email 1 (sent)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 2 (draft)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 3 (sent)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 4 (draft)" })
      end

      it "deletes an email" do
        visit "#{emails_path}/scheduled"
        wait_for_ajax

        find(:table_row, { name: "Email 5 (scheduled)" }).click
        within_section "Email 5 (scheduled)", section_element: :aside do
          click_on "Delete"
        end

        within_modal "Delete email?" do
          expect(page).to have_text("Are you sure you want to delete the email \"Email 5 (scheduled)\"? This action cannot be undone.")
          click_on "Delete email"
        end
        wait_for_ajax
        expect(page).to have_alert(text: "Email deleted!")

        expect(page).to_not have_table_row({ "Subject" => "Email 5 (scheduled)" })

        expect(installment5.reload.deleted_at).to_not be_nil
      end
    end

    describe "draft emails" do
      it "shows draft emails" do
        visit "#{emails_path}/drafts"
        wait_for_ajax

        expect(page).to have_table_row({ "Subject" => "Email 2 (draft)", "Sent to" => "Customers of Product name", "Audience" => "1" })
        expect(page).to have_table_row({ "Subject" => "Email 4 (draft)", "Sent to" => "Customers of Product name", "Audience" => "1" })
        expect(page).to_not have_table_row({ "Subject" => "Email 1 (sent)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 3 (sent)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 5 (scheduled)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 6 (scheduled)" })
      end

      it "paginates emails ordered by recently updated first" do
        stub_const("PaginatedInstallmentsPresenter::PER_PAGE", 2)

        visit "#{emails_path}/drafts"
        wait_for_ajax

        expect(page).to have_table_row({ "Subject" => "Email 2 (draft)" })
        expect(page).to have_table_row({ "Subject" => "Email 4 (draft)" })

        expect(page).to_not have_button("Load more")

        create(:installment, name: "Hello world!", seller:, link: product)
        refresh

        expect(page).to have_table_row({ "Subject" => "Hello world!", "Sent to" => "Customers of Product name", "Audience" => "1" })
        expect(page).to have_table_row({ "Subject" => "Email 2 (draft)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 4 (draft)" })

        click_on "Load more"
        wait_for_ajax

        expect(page).to have_table_row({ "Subject" => "Hello world!" })
        expect(page).to have_table_row({ "Subject" => "Email 2 (draft)" })
        expect(page).to have_table_row({ "Subject" => "Email 4 (draft)" })

        expect(page).to_not have_button("Load more")
      end

      it "deletes an email" do
        visit "#{emails_path}/drafts"
        wait_for_ajax

        find(:table_row, { name: "Email 2 (draft)" }).click
        within_section "Email 2 (draft)", section_element: :aside do
          click_on "Delete"
        end

        within_modal "Delete email?" do
          expect(page).to have_text("Are you sure you want to delete the email \"Email 2 (draft)\"? This action cannot be undone.")
          click_on "Delete email"
        end
        wait_for_ajax
        expect(page).to have_alert(text: "Email deleted!")

        expect(page).to_not have_table_row({ "Subject" => "Email 2 (draft)" })

        expect(installment2.reload.deleted_at).to_not be_nil
      end
    end

    describe "search" do
      it "displays filtered and paginated emails for the search query" do
        stub_const("PaginatedInstallmentsPresenter::PER_PAGE", 1)

        create(:installment, name: "Hello world", seller:, link: product, published_at: 10.days.ago) # does not match 'name' or 'message'
        create(:installment, name: "Thank you!", message: "Thank you email", seller:, link: product, published_at: 1.month.ago) # matches the 'message'
        create(:installment, name: "Email 7 (sent)", published_at: 10.days.ago) # another seller's email, so won't match

        visit "#{emails_path}/published"
        wait_for_ajax

        select_disclosure "Toggle Search" do
          fill_in "Search emails", with: "email"
        end
        wait_for_ajax

        expect(page).to have_table_row({ "Subject" => "Thank you!" })

        expect(page).to_not have_table_row({ "Subject" => "Email 1 (sent)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 2 (draft)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 3 (sent)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 4 (draft)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 5 (scheduled)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 6 (scheduled)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 7 (sent)" })
        expect(page).to_not have_table_row({ "Subject" => "Hello world" })

        click_on "Load more"
        wait_for_ajax

        expect(page).to have_table_row({ "Subject" => "Thank you!" })
        expect(page).to have_table_row({ "Subject" => "Email 3 (sent)" })

        expect(page).to_not have_table_row({ "Subject" => "Email 1 (sent)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 2 (draft)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 4 (draft)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 5 (scheduled)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 6 (scheduled)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 7 (sent)" })
        expect(page).to_not have_table_row({ "Subject" => "Hello world" })

        click_on "Load more"
        wait_for_ajax

        expect(page).to have_table_row({ "Subject" => "Thank you!" })
        expect(page).to have_table_row({ "Subject" => "Email 3 (sent)" })
        expect(page).to have_table_row({ "Subject" => "Email 1 (sent)" })

        expect(page).to_not have_table_row({ "Subject" => "Email 2 (draft)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 4 (draft)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 5 (scheduled)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 6 (scheduled)" })
        expect(page).to_not have_table_row({ "Subject" => "Email 7 (sent)" })
        expect(page).to_not have_table_row({ "Subject" => "Hello world" })

        expect(page).to_not have_button("Load more")
      end

      it "searches emails for the corresponding tab" do
        create(:installment, name: "Published post", seller:, link: product, published_at: 10.days.ago)
        create(:installment, seller:, link: product, name: "Draft post", message: "test", created_at: 1.hour.ago)
        create(:scheduled_installment, seller:, link: product, name: "Scheduled Post")

        visit "#{emails_path}/published"
        wait_for_ajax

        select_disclosure "Toggle Search" do
          fill_in "Search emails", with: "email"
        end
        wait_for_ajax

        expect(page).to have_table_row(count: 3) # including header row
        expect(page).to have_table_row({ "Subject" => "Email 1 (sent)" })
        expect(page).to have_table_row({ "Subject" => "Email 3 (sent)" })

        expect(page).to_not have_table_row({ "Subject" => "Published post" })

        # Reset the search
        fill_in "Search emails", with: ""
        wait_for_ajax

        expect(page).to have_table_row(count: 4) # including header row
        expect(page).to have_table_row({ "Subject" => "Email 1 (sent)" })
        expect(page).to have_table_row({ "Subject" => "Email 3 (sent)" })
        expect(page).to have_table_row({ "Subject" => "Published post" })

        select_tab "Scheduled"
        wait_for_ajax

        select_disclosure "Toggle Search" do
          fill_in "Search emails", with: "email"
        end
        wait_for_ajax

        expect(page).to have_table_row(count: 3) # including header row
        expect(page).to have_table_row({ "Subject" => "Email 5 (scheduled)" })
        expect(page).to have_table_row({ "Subject" => "Email 6 (scheduled)" })

        expect(page).to_not have_table_row({ "Subject" => "Scheduled Post" })

        # Reset the search
        fill_in "Search emails", with: ""
        wait_for_ajax

        expect(page).to have_table_row(count: 4) # including header row
        expect(page).to have_table_row({ "Subject" => "Email 5 (scheduled)" })
        expect(page).to have_table_row({ "Subject" => "Email 6 (scheduled)" })
        expect(page).to have_table_row({ "Subject" => "Scheduled Post" })

        select_tab "Drafts"
        wait_for_ajax

        select_disclosure "Toggle Search" do
          fill_in "Search emails", with: "email"
        end
        wait_for_ajax

        expect(page).to have_table_row(count: 3) # including header row
        expect(page).to have_table_row({ "Subject" => "Email 2 (draft)" })
        expect(page).to have_table_row({ "Subject" => "Email 4 (draft)" })

        expect(page).to_not have_table_row({ "Subject" => "Draft post" })

        # Reset the search
        fill_in "Search emails", with: ""
        wait_for_ajax

        expect(page).to have_table_row(count: 4) # including header row
        expect(page).to have_table_row({ "Subject" => "Email 2 (draft)" })
        expect(page).to have_table_row({ "Subject" => "Email 4 (draft)" })
        expect(page).to have_table_row({ "Subject" => "Draft post" })
      end
    end
  end
end
