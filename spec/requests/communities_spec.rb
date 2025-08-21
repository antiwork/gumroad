# frozen_string_literal: true

require "spec_helper"

describe "Communities", :js, type: :system do
  let(:seller) { create(:user, name: "Bob") }

  before do
    Feature.activate_user(:communities, seller)
  end

  def find_message(content)
    content_element = find("[aria-label='Message content']", text: content, match: :first)
    content_element.ancestor("[aria-label='Chat message']", match: :first)
  end

  def have_message(content)
    have_selector("[aria-label='Message content']", text: content, match: :first)
  end

  context "when the logged in seller has an active community" do
    let(:product) { create(:product, name: "Mastering Rails", user: seller, community_chat_enabled: true) }
    let!(:community) { create(:community, resource: product, seller:) }

    before do
      login_as(seller)
    end

    it "shows the community and allows the seller to send, edit, and delete own messages" do
      visit community_path

      wait_for_ajax

      expect(page).to have_current_path(community_path(seller.external_id, community.external_id))

      within "[aria-label='Sidebar']" do
        within "[aria-label='Community switcher area']" do
          expect(page).to have_text("My community")
        end

        within "[aria-label='Community list']" do
          expect(page).to have_link("Mastering Rails", href: community_path(seller.external_id, community.external_id))
          expect(find_link("Mastering Rails")["aria-selected"]).to eq("true")
        end
      end

      within "[aria-label='Chat window']" do
        within "[aria-label='Community chat header']" do
          expect(page).to have_text("Mastering Rails")
        end

        within "[aria-label='Chat messages']" do
          expect(page).to have_text("Welcome to Mastering Rails")
          expect(page).to have_text("This is the start of this community chat.")
        end

        fill_in "Type a message", with: "Hello, world!"
        click_button "Send message"
        wait_for_ajax

        message = community.community_chat_messages.sole
        expect(message.content).to eq("Hello, world!")
        expect(message.user).to eq(seller)

        within "[aria-label='Chat messages']" do
          expect(page).to have_message("Hello, world!")
          message_element = find_message("Hello, world!")
          message_element.hover
          within message_element do
            expect(page).to have_text(seller.display_name)
            expect(page).to have_text("CREATOR")
            expect(page).to have_button("Edit message")
            expect(page).to have_button("Delete message")

            click_button "Edit message"
            fill_in "Edit message", with: "This is wonderful!"
            sleep 0.5 # wait for the state to update
            click_on "Save"
            wait_for_ajax
          end

          expect(page).to have_message("This is wonderful!")
          expect(page).not_to have_message("Hello, world!")

          expect(message.reload.content).to eq("This is wonderful!")

          within message_element do
            click_button "Delete message"
            within_modal "Delete message" do
              expect(page).to have_text("Are you sure you want to delete this message? This cannot be undone.")
              click_on "Delete"
            end
            wait_for_ajax
          end

          expect(page).not_to have_message("This is wonderful!")
          expect(message.reload).to be_deleted
          expect(community.community_chat_messages.alive).to be_empty
        end
      end
    end

    it "allows seller to delete messages from other community members" do
      customer = create(:user, name: "John Customer")
      customer_message = create(:community_chat_message, community:, user: customer, content: "Hello, world!")

      visit community_path

      customer_message_element = find_message("Hello, world!")
      customer_message_element.hover
      within customer_message_element do
        expect(page).to have_text("John Customer")
        expect(page).not_to have_text("CREATOR")
        expect(page).not_to have_button("Edit message")
        expect(page).to have_button("Delete message")

        click_button "Delete message"
        within_modal "Delete message" do
          expect(page).to have_text("Are you sure you want to delete this message? This cannot be undone.")
          click_on "Delete"
        end
      end
      wait_for_ajax

      expect(page).not_to have_message("Hello, world!")
      expect(customer_message.reload).to be_deleted
      expect(community.community_chat_messages.alive).to be_empty
    end

    it "allows seller to manage community notification settings" do
      visit community_path

      expect(seller.community_notification_settings.find_by(seller:)).to be_nil

      within "[aria-label='Community switcher area']" do
        select_disclosure "Switch creator"

        click_on "Notifications"
      end

      within_modal "Notifications" do
        expect(page).to have_text(%Q(Receive email recaps of what's happening in "Bob" community.))
        expect(page).to have_unchecked_field("Community recap")
        expect(page).not_to have_radio_button("Daily")
        expect(page).not_to have_radio_button("Weekly")

        check "Community recap"
        expect(page).to have_radio_button("Daily", checked: false)
        expect(page).to have_radio_button("Weekly", checked: true)

        click_on "Save"
      end

      wait_for_ajax
      expect(page).to have_alert(text: "Changes saved!")
      expect(seller.reload.community_notification_settings.find_by(seller:).recap_frequency).to eq("weekly")

      within "[aria-label='Community switcher area']" do
        select_disclosure "Switch creator"
        click_on "Notifications"
      end

      within_modal "Notifications" do
        expect(page).to have_checked_field("Community recap")
        expect(page).to have_radio_button("Daily", checked: false)
        expect(page).to have_radio_button("Weekly", checked: true)
        choose "Daily"
        click_on "Save"
      end

      wait_for_ajax
      expect(page).to have_alert(text: "Changes saved!")
      expect(seller.reload.community_notification_settings.find_by(seller:).recap_frequency).to eq("daily")

      within "[aria-label='Community switcher area']" do
        select_disclosure "Switch creator"
        click_on "Notifications"
      end

      within_modal "Notifications" do
        expect(page).to have_checked_field("Community recap")
        expect(page).to have_radio_button("Daily", checked: true)
        expect(page).to have_radio_button("Weekly", checked: false)
        uncheck "Community recap"
        expect(page).not_to have_radio_button("Daily")
        expect(page).not_to have_radio_button("Weekly")
        click_on "Save"
      end

      wait_for_ajax
      expect(page).to have_alert(text: "Changes saved!")
      expect(seller.reload.community_notification_settings.find_by(seller:).recap_frequency).to be_nil
    end

    it "allows seller to switch between own communities" do
      product2 = create(:product, name: "Scaling web apps", user: seller, community_chat_enabled: true)
      community2 = create(:community, resource: product2, seller:)
      create(:community_chat_message, community: community2, user: seller, content: "Are you ready to scale your web app?")

      visit community_path

      wait_for_ajax
      within "[aria-label='Sidebar']" do
        within "[aria-label='Community list']" do
          expect(page).to have_link("Mastering Rails", href: community_path(seller.external_id, community.external_id))
          expect(page).to have_link("Scaling web apps", href: community_path(seller.external_id, community2.external_id))
          expect(find_link("Mastering Rails")["aria-selected"]).to eq("true")
          expect(find_link("Scaling web apps")["aria-selected"]).to eq("false")
        end
      end

      within "[aria-label='Chat window']" do
        within "[aria-label='Community chat header']" do
          expect(page).to have_text("Mastering Rails")
        end

        within "[aria-label='Chat messages']" do
          expect(page).to have_text("Welcome to Mastering Rails")
        end
      end

      within "[aria-label='Sidebar']" do
        click_link "Scaling web apps"
        wait_for_ajax
        within "[aria-label='Community list']" do
          expect(find_link("Mastering Rails")["aria-selected"]).to eq("false")
          expect(find_link("Scaling web apps")["aria-selected"]).to eq("true")
        end
      end

      within "[aria-label='Chat window']" do
        within "[aria-label='Community chat header']" do
          expect(page).to have_text("Scaling web apps")
        end

        within "[aria-label='Chat messages']" do
          expect(page).to have_message("Are you ready to scale your web app?")
        end

        fill_in "Type a message", with: "Wow, this is amazing!"
        click_button "Send message"
        wait_for_ajax

        message = community2.community_chat_messages.last
        expect(message.content).to eq("Wow, this is amazing!")
        expect(message.user).to eq(seller)

        within "[aria-label='Chat messages']" do
          message_element = find_message("Wow, this is amazing!")
          message_element.hover
          within message_element do
            expect(page).to have_text("Bob")
            expect(page).to have_text("CREATOR")
            expect(page).to have_button("Edit message")
            expect(page).to have_button("Delete message")
          end
        end
      end

      within "[aria-label='Sidebar']" do
        click_link "Mastering Rails"
        wait_for_ajax
        within "[aria-label='Community list']" do
          expect(find_link("Mastering Rails")["aria-selected"]).to eq("true")
          expect(find_link("Scaling web apps")["aria-selected"]).to eq("false")
        end
      end

      within "[aria-label='Chat window']" do
        within "[aria-label='Community chat header']" do
          expect(page).to have_text("Mastering Rails")
        end

        within "[aria-label='Chat messages']" do
          expect(page).not_to have_message("Are you ready to scale your web app?")
          expect(page).not_to have_message("Wow, this is amazing!")
          expect(page).to have_text("Welcome to Mastering Rails")
        end
      end
    end
  end

  context "when a customer accesses the community" do
    let(:product) { create(:product, name: "Mastering Rails", user: seller, community_chat_enabled: true) }
    let!(:community) { create(:community, resource: product, seller:) }
    let(:buyer) { create(:user, name: "John Buyer") }
    let!(:purchase) { create(:purchase, seller:, purchaser: buyer, link: product) }
    let!(:seller_message) { create(:community_chat_message, community:, user: seller, content: "Hello from seller!") }
    let!(:another_customer_message) { create(:community_chat_message, community:, user: create(:user, name: "Jane"), content: "Hello from Jane!") }

    before do
      login_as(buyer)
    end

    it "shows the community and allows the buyer to send, edit, and delete own messages" do
      visit community_path

      wait_for_ajax
      within "[aria-label='Sidebar']" do
        within "[aria-label='Community switcher area']" do
          expect(page).to have_text("Bob")
        end

        within "[aria-label='Community list']" do
          expect(page).to have_link("Mastering Rails", href: community_path(seller.external_id, community.external_id))
          expect(find_link("Mastering Rails")["aria-selected"]).to eq("true")
        end
      end

      within "[aria-label='Chat window']" do
        within "[aria-label='Community chat header']" do
          expect(page).to have_text("Mastering Rails")
        end

        within "[aria-label='Chat messages']" do
          expect(page).to have_text("Welcome to Mastering Rails")
          expect(page).to have_text("This is the start of this community chat.")

          expect(page).to have_message("Hello from seller!")
          expect(page).to have_message("Hello from Jane!")
        end

        fill_in "Type a message", with: "Hello from John!"
        click_button "Send message"
        wait_for_ajax

        message = community.community_chat_messages.last
        expect(message.content).to eq("Hello from John!")
        expect(message.user).to eq(buyer)

        within "[aria-label='Chat messages']" do
          expect(page).to have_message("Hello from John!")
          message_element = find_message("Hello from John!")
          message_element.hover
          within message_element do
            expect(page).to have_text("John Buyer")
            expect(page).not_to have_text("CREATOR")
            expect(page).to have_button("Edit message")
            expect(page).to have_button("Delete message")

            click_button "Edit message"
            fill_in "Edit message", with: "This is wonderful!"
            sleep 0.5 # wait for the state to update
            click_on "Save"
            wait_for_ajax
          end

          expect(page).to have_message("This is wonderful!")
          expect(page).not_to have_message("Hello from John!")

          expect(message.reload.content).to eq("This is wonderful!")

          within message_element do
            click_button "Delete message"
            within_modal "Delete message" do
              expect(page).to have_text("Are you sure you want to delete this message? This cannot be undone.")
              click_on "Delete"
            end
            wait_for_ajax
          end

          expect(page).not_to have_message("This is wonderful!")
          expect(message.reload).to be_deleted
          expect(community.community_chat_messages.alive.count).to eq(2)

          message_from_another_customer = find_message("Hello from Jane!")
          message_from_another_customer.hover
          within message_from_another_customer do
            expect(page).to have_text("Jane")
            expect(page).not_to have_text("CREATOR")
            expect(page).not_to have_button("Edit message")
            expect(page).not_to have_button("Delete message")
          end

          message_from_seller = find_message("Hello from seller!")
          message_from_seller.hover
          within message_from_seller do
            expect(page).to have_text("Bob")
            expect(page).to have_text("CREATOR")
            expect(page).not_to have_button("Edit message")
            expect(page).not_to have_button("Delete message")
          end
        end
      end
    end

    it "allows buyer to manage community notification settings" do
      visit community_path

      expect(buyer.community_notification_settings.find_by(seller:)).to be_nil

      within "[aria-label='Community switcher area']" do
        select_disclosure "Switch creator"

        click_on "Notifications"
      end

      within_modal "Notifications" do
        expect(page).to have_text(%Q(Receive email recaps of what's happening in "Bob" community.))
        expect(page).to have_unchecked_field("Community recap")
        expect(page).not_to have_radio_button("Daily")
        expect(page).not_to have_radio_button("Weekly")

        check "Community recap"
        expect(page).to have_radio_button("Daily", checked: false)
        expect(page).to have_radio_button("Weekly", checked: true)

        click_on "Save"
      end

      wait_for_ajax
      expect(page).to have_alert(text: "Changes saved!")
      expect(buyer.reload.community_notification_settings.find_by(seller:).recap_frequency).to eq("weekly")

      within "[aria-label='Community switcher area']" do
        select_disclosure "Switch creator"
        click_on "Notifications"
      end

      within_modal "Notifications" do
        expect(page).to have_checked_field("Community recap")
        expect(page).to have_radio_button("Daily", checked: false)
        expect(page).to have_radio_button("Weekly", checked: true)
        choose "Daily"
        click_on "Save"
      end

      wait_for_ajax
      expect(page).to have_alert(text: "Changes saved!")
      expect(buyer.reload.community_notification_settings.find_by(seller:).recap_frequency).to eq("daily")

      within "[aria-label='Community switcher area']" do
        select_disclosure "Switch creator"
        click_on "Notifications"
      end

      within_modal "Notifications" do
        expect(page).to have_checked_field("Community recap")
        expect(page).to have_radio_button("Daily", checked: true)
        expect(page).to have_radio_button("Weekly", checked: false)
        uncheck "Community recap"
        expect(page).not_to have_radio_button("Daily")
        expect(page).not_to have_radio_button("Weekly")
        click_on "Save"
      end

      wait_for_ajax
      expect(page).to have_alert(text: "Changes saved!")
      expect(buyer.reload.community_notification_settings.find_by(seller:).recap_frequency).to be_nil
    end

    it "allows buyer to switch between communities from the same seller" do
      product2 = create(:product, name: "Scaling web apps", user: seller, community_chat_enabled: true)
      community2 = create(:community, resource: product2, seller:)
      create(:purchase, seller:, purchaser: buyer, link: product2)
      create(:community_chat_message, community: community2, user: seller, content: "Are you ready to scale your web app?")

      visit community_path

      wait_for_ajax

      expect(page).to have_current_path(community_path(seller.external_id, community.external_id))

      within "[aria-label='Sidebar']" do
        within "[aria-label='Community switcher area']" do
          expect(page).to have_text("Bob")
        end

        within "[aria-label='Community list']" do
          expect(page).to have_link("Mastering Rails", href: community_path(seller.external_id, community.external_id))
          expect(page).to have_link("Scaling web apps", href: community_path(seller.external_id, community2.external_id))
          community1_link_element = find_link("Mastering Rails")
          within community1_link_element do
            within "[aria-label='Unread message count']" do
              expect(page).to have_text("2")
            end
          end
          expect(community1_link_element["aria-selected"]).to eq("true")
          community2_link_element = find_link("Scaling web apps")
          within community2_link_element do
            within "[aria-label='Unread message count']" do
              expect(page).to have_text("1")
            end
          end
          expect(community2_link_element["aria-selected"]).to eq("false")
        end
      end

      within "[aria-label='Chat window']" do
        within "[aria-label='Community chat header']" do
          expect(page).to have_text("Mastering Rails")
        end

        within "[aria-label='Chat messages']" do
          expect(page).to have_text("Welcome to Mastering Rails")
          expect(page).to have_message("Hello from seller!")
          expect(page).to have_message("Hello from Jane!")
        end
      end

      within "[aria-label='Sidebar']" do
        click_link "Scaling web apps"
        wait_for_ajax
        within "[aria-label='Community list']" do
          expect(find_link("Mastering Rails")["aria-selected"]).to eq("false")
          expect(find_link("Scaling web apps")["aria-selected"]).to eq("true")
        end
      end

      expect(page).to have_current_path(community_path(seller.external_id, community2.external_id))

      within "[aria-label='Chat window']" do
        within "[aria-label='Community chat header']" do
          expect(page).to have_text("Scaling web apps")
        end

        within "[aria-label='Chat messages']" do
          expect(page).to have_message("Are you ready to scale your web app?")
          expect(page).not_to have_message("Hello from Jane!")
          expect(page).not_to have_message("Hello from seller!")
        end

        fill_in "Type a message", with: "Wow, this is amazing!"
        click_button "Send message"
        wait_for_ajax

        message = community2.community_chat_messages.last
        expect(message.content).to eq("Wow, this is amazing!")
        expect(message.user).to eq(buyer)

        within "[aria-label='Chat messages']" do
          message_element = find_message("Wow, this is amazing!")
          message_element.hover
          within message_element do
            expect(page).to have_text("John Buyer")
            expect(page).not_to have_text("CREATOR")
            expect(page).to have_button("Edit message")
            expect(page).to have_button("Delete message")
          end
        end
      end

      within "[aria-label='Sidebar']" do
        click_link "Mastering Rails"
        wait_for_ajax
        within "[aria-label='Community list']" do
          expect(find_link("Mastering Rails")["aria-selected"]).to eq("true")
          expect(find_link("Scaling web apps")["aria-selected"]).to eq("false")
        end
      end

      within "[aria-label='Chat window']" do
        within "[aria-label='Community chat header']" do
          expect(page).to have_text("Mastering Rails")
        end

        within "[aria-label='Chat messages']" do
          expect(page).not_to have_message("Are you ready to scale your web app?")
          expect(page).not_to have_message("Wow, this is amazing!")
          expect(page).to have_text("Welcome to Mastering Rails")
          expect(page).to have_message("Hello from seller!")
          expect(page).to have_message("Hello from Jane!")
        end
      end
    end

    it "allows buyer to switch between communities from different sellers" do
      other_seller = create(:user, name: "Alice")
      Feature.activate_user(:communities, other_seller)
      other_product = create(:product, name: "The ultimate guide to design systems", user: other_seller, community_chat_enabled: true)
      other_community = create(:community, resource: other_product, seller: other_seller)
      create(:purchase, seller: other_seller, purchaser: buyer, link: other_product)
      create(:community_chat_message, community: other_community, user: other_seller, content: "Get excited!")

      visit community_path

      wait_for_ajax

      expect(page).to have_current_path(community_path(seller.external_id, community.external_id))

      within "[aria-label='Sidebar']" do
        within "[aria-label='Community switcher area']" do
          expect(page).to have_text("Bob")
        end

        within "[aria-label='Community list']" do
          expect(page).to have_link("Mastering Rails", href: community_path(seller.external_id, community.external_id))
          expect(page).not_to have_link("The ultimate guide to design systems")
          expect(find_link("Mastering Rails")["aria-selected"]).to eq("true")
          within find_link("Mastering Rails") do
            within "[aria-label='Unread message count']" do
              expect(page).to have_text("2")
            end
          end
        end
      end

      within "[aria-label='Chat window']" do
        within "[aria-label='Community chat header']" do
          expect(page).to have_text("Mastering Rails")
        end

        within "[aria-label='Chat messages']" do
          expect(page).to have_text("Welcome to Mastering Rails")
          expect(page).to have_message("Hello from seller!")
          expect(page).to have_message("Hello from Jane!")
          expect(page).not_to have_message("Get excited!")
        end
      end

      within "[aria-label='Sidebar']" do
        select_disclosure "Switch creator"
        click_on "Alice"
        wait_for_ajax
        within "[aria-label='Community switcher area']" do
          expect(page).to have_text("Alice")
        end

        expect(page).to have_current_path(community_path(other_seller.external_id, other_community.external_id))
        refresh

        within "[aria-label='Community list']" do
          expect(page).to have_link("The ultimate guide to design systems", href: community_path(other_seller.external_id, other_community.external_id))
          expect(page).not_to have_link("Mastering Rails")
          expect(find_link("The ultimate guide to design systems")["aria-selected"]).to eq("true")
          within find_link("The ultimate guide to design systems") do
            within "[aria-label='Unread message count']" do
              expect(page).to have_text("1")
            end
          end
        end
      end

      within "[aria-label='Chat window']" do
        within "[aria-label='Community chat header']" do
          expect(page).to have_text("The ultimate guide to design systems")
        end

        within "[aria-label='Chat messages']" do
          expect(page).to have_message("Get excited!")
          expect(page).not_to have_message("Hello from Jane!")
          expect(page).not_to have_message("Hello from seller!")
        end

        fill_in "Type a message", with: "This is great!"
        click_button "Send message"
        wait_for_ajax

        message = other_community.community_chat_messages.last
        expect(message.content).to eq("This is great!")
        expect(message.user).to eq(buyer)

        within "[aria-label='Chat messages']" do
          message_element = find_message("This is great!")
          message_element.hover
          within message_element do
            expect(page).to have_text("John Buyer")
            expect(page).not_to have_text("CREATOR")
            expect(page).to have_button("Edit message")
            expect(page).to have_button("Delete message")
          end
        end
      end

      within "[aria-label='Sidebar']" do
        select_disclosure "Switch creator"
        click_on "Bob"
        wait_for_ajax
        within "[aria-label='Community switcher area']" do
          expect(page).to have_text("Bob")
        end

        expect(page).to have_current_path(community_path(seller.external_id, community.external_id))
        refresh

        within "[aria-label='Community list']" do
          expect(find_link("Mastering Rails")["aria-selected"]).to eq("true")
          expect(page).not_to have_link("The ultimate guide to design systems")
        end
      end

      within "[aria-label='Chat window']" do
        within "[aria-label='Community chat header']" do
          expect(page).to have_text("Mastering Rails")
        end

        within "[aria-label='Chat messages']" do
          expect(page).not_to have_message("Get excited!")
          expect(page).not_to have_message("This is great!")
          expect(page).to have_text("Welcome to Mastering Rails")
          expect(page).to have_message("Hello from seller!")
          expect(page).to have_message("Hello from Jane!")
        end
      end
    end

    it "allows accessing a community directly via URL" do
      visit community_path(seller.external_id, community.external_id)

      wait_for_ajax
      within "[aria-label='Sidebar']" do
        within "[aria-label='Community switcher area']" do
          expect(page).to have_text("Bob")
        end

        within "[aria-label='Community list']" do
          expect(page).to have_link("Mastering Rails", href: community_path(seller.external_id, community.external_id))
          expect(find_link("Mastering Rails")["aria-selected"]).to eq("true")
        end
      end

      within "[aria-label='Chat window']" do
        within "[aria-label='Community chat header']" do
          expect(page).to have_text("Mastering Rails")
        end

        within "[aria-label='Chat messages']" do
          expect(page).to have_text("Welcome to Mastering Rails")
          expect(page).to have_message("Hello from seller!")
          expect(page).to have_message("Hello from Jane!")
        end
      end
    end

    it "does not allow accessing a community directly via URL if user cannot access it" do
      purchase.destroy!

      visit community_path(seller.external_id, community.external_id)

      expect(page).to have_alert(text: "You are not allowed to perform this action.")
      expect(page).to have_current_path(dashboard_path)
    end

    it "opens notifications modal when accessing community URL with notifications parameter" do
      visit community_path(seller.external_id, community.external_id, notifications: "true")

      wait_for_ajax
      within "[aria-label='Sidebar']" do
        within "[aria-label='Community switcher area']" do
          expect(page).to have_text("Bob")
        end
      end

      within_modal "Notifications" do
        expect(page).to have_text(%Q(Receive email recaps of what's happening in "Bob" community.))
        expect(page).to have_unchecked_field("Community recap")
        expect(page).not_to have_radio_button("Daily")
        expect(page).not_to have_radio_button("Weekly")
      end
    end
  end
end
