# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Settings > Team Scenario", type: :system, js: true) do
  let(:seller) { create(:named_seller) }

  def team_layout
    page.evaluate_script(<<~JS)
      [...document.querySelectorAll('form input, form button, form table')].map((element) => {
        let x = 0, y = 0;
        for (let parent = element; parent; parent = parent.offsetParent) {
          x += parent.offsetLeft;
          y += parent.offsetTop;
        }
        return [x, y, element.offsetWidth, element.offsetHeight];
      })
    JS
  end

  def expect_bottom_invitation_error
    expect(page).to have_alert(text: /You've reached the limit of 10 team invitations per hour/)
    expect(page.evaluate_script(<<~JS)).to eq(["fixed", "16px"])
      (() => {
        const style = getComputedStyle(document.querySelector('[data-testid=toast-alert]'));
        return [style.position, style.bottom];
      })()
    JS
  end

  shared_examples_for "leaves the team" do
    it "deletes membership and switches account" do
      visit settings_team_path

      within_section("Team members", section_element: :section) do
        within find(:table_row, { "Member" => user_with_role_for_seller.display_name }) do
          click_on("Leave team")
        end
      end

      within_modal "Leave team?" do
        expect(page).to have_text("Are you sure you want to leave Seller team? Once you leave the team you will no longer have access.")
        click_on "Yes, leave team"
      end

      wait_for_ajax
      expect(seller.seller_memberships.find_by(user: user_with_role_for_seller).deleted?).to eq(true)

      within 'nav[aria-label="Main"]' do
        expect(page).to have_text(user_with_role_for_seller.display_name)
      end
      expect(page).to have_text("Welcome")
    end
  end

  context "with switching account to user as admin for seller" do
    include_context "with switching account to user as admin for seller"

    describe "Add team members section" do
      it "displays only allowed roles" do
        visit settings_team_path

        within_section("Add team members", section_element: :section) do
          find("label", text: "Role").click
          expect(page).to have_combo_box(
            "Role",
            options: TeamInvitation::ROLES.map { |role| role.humanize }
          )
        end
      end

      it "shows the invitation limit without moving the form and allows a successful retry" do
        10.times { TeamInvitationThrottle.check(seller.id) }
        visit settings_team_path

        within_section("Add team members", section_element: :section) do
          fill_in("Email", with: "new@example.com")
          select_combo_box_option("Admin", from: "Role")
        end
        layout = team_layout
        click_on("Send invitation")
        expect_bottom_invitation_error
        expect(page).to have_button("Send invitation", disabled: false)
        expect(team_layout).to eq(layout)
        expect(seller.team_invitations.find_by(email: "new@example.com")).to be_nil

        $redis.del(RedisKey.team_invitation_send_throttle(seller.id))
        within_section("Add team members", section_element: :section) do
          click_on("Send invitation")
        end
        expect(page).to have_alert(text: "Invitation sent!")
        expect(page).not_to have_alert(text: /You've reached the limit/)
        expect(page.evaluate_script("getComputedStyle(document.querySelector('[data-testid=toast-alert]')).top")).to eq("16px")
        expect(seller.team_invitations.find_by(email: "new@example.com")).to be_present
      end

      it "submits the form and refreshes the table" do
        visit settings_team_path

        within_section("Add team members", section_element: :section) do
          fill_in("Email", with: "new@example.com")
          select_combo_box_option("Admin", from: "Role")
          click_on("Send invitation")
        end

        wait_for_ajax

        within_section("Team members", section_element: :section) do
          expect(page).to have_content "new@example.com"
        end
      end
    end

    describe "Team members section" do
      let(:user) { create(:user, name: "Joe") }
      let!(:team_membership) { create(:team_membership, seller:, user:, role: TeamMembership::ROLE_MARKETING) }
      let!(:team_invitation) { create(:team_invitation, seller:, email: "member@example.com") }

      it "renders the table" do
        visit settings_team_path

        within_section("Team members", section_element: :section) do
          expect(page).to have_content seller.display_name

          expect find(:table_row, { "Member" => "Seller", "Role" => "Owner" })
          expect(find(:table_row, { "Member" => user_with_role_for_seller.display_name, "Role" => "Admin" })).to have_button("Leave team")
        end
      end

      it "removes and restores team membership" do
        visit settings_team_path

        within_section("Team members", section_element: :section) do
          within find(:table_row, { "Member" => "Joe" }) do
            select_combo_box_option("Remove from team")
          end

          wait_for_ajax
          expect(page).to have_alert(text: "Joe was removed from team members")

          within find(:table) do
            expect(page).not_to have_content "Joe"
          end
          click_on "Undo"
        end

        wait_for_ajax
        expect(page).to have_alert(text: "Joe was added back to the team")

        within_section("Team members", section_element: :section) do
          expect(page).not_to have_button("Undo")
          expect(find(:table_row, { "Member" => "Joe", "Role" => "Marketing" }))
        end
      end

      it "removes and restores team invitation" do
        visit settings_team_path

        within_section("Team members", section_element: :section) do
          within find(:table_row, { "Member" => team_invitation.email }) do
            select_combo_box_option("Remove from team")
          end

          wait_for_ajax
          expect(page).to have_alert(text: "#{team_invitation.email} was removed from team members")

          within find(:table) do
            expect(page).not_to have_content team_invitation.email
          end

          click_on "Undo"
        end

        wait_for_ajax
        expect(page).to have_alert(text: "#{team_invitation.email} was added back to the team")

        within_section("Team members", section_element: :section) do
          expect(page).not_to have_button("Undo")
          expect(find(:table_row, { "Member" => "member@example.com", "Role" => "Admin" }))
        end
      end

      it "updates role" do
        visit settings_team_path

        within_section("Team members", section_element: :section) do
          within find(:table_row, { "Member" => "Joe", "Role" => "Marketing" }) do
            select_combo_box_option("Admin")
          end
        end

        wait_for_ajax
        expect(page).to have_alert(text: "Role for Joe has changed to Admin")

        within_section("Team members", section_element: :section) do
          expect find(:table_row, { "Member" => "Joe", "Role" => "Admin" })
        end
      end

      it_behaves_like "leaves the team"

      context "with expired invitation" do
        before do
          team_invitation.update!(expires_at: 1.minute.ago)
        end

        it "shows the resend limit without moving the row and allows a successful retry" do
          10.times { TeamInvitationThrottle.check(seller.id) }
          visit settings_team_path

          layout = team_layout
          within find(:table_row, { "Member" => team_invitation.email }) do
            select_combo_box_option("Resend invitation")
          end
          expect_bottom_invitation_error
          expect(team_layout).to eq(layout)
          expect(team_invitation.reload).to be_expired
          within '[data-testid="toast-alert"]' do
            click_on "Close"
          end
          expect(page).not_to have_alert(text: /You've reached the limit/)
          expect(team_layout).to eq(layout)

          $redis.del(RedisKey.team_invitation_send_throttle(seller.id))
          within find(:table_row, { "Member" => team_invitation.email }) do
            find(:combo_box, visible: :all).find(:xpath, "..").click
            select_combo_box_option("Resend invitation")
          end
          expect(page).to have_alert(text: "Invitation sent!")
          expect(page).not_to have_alert(text: /You've reached the limit/)
          expect(team_invitation.reload).not_to be_expired
        end

        it "resends invitation" do
          visit settings_team_path

          within_section("Team members", section_element: :section) do
            within find(:table_row, { "Member" => team_invitation.email }) do
              select_combo_box_option("Resend invitation")
            end
          end

          wait_for_ajax
          expect(page).to have_alert(text: "Invitation sent!")
        end
      end
    end
  end

  context "with switching account to user as marketing for seller" do
    include_context "with switching account to user as marketing for seller"

    it_behaves_like "leaves the team"
  end
end
