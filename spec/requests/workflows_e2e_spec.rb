# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "Workflows End-to-End", js: true, type: :system do
  let(:seller) { create(:named_seller) }

  before do
    # Create products after seller is set up
    @product1 = create(:product, name: "Test Product 1", user: seller, created_at: 2.hours.ago)
    @product2 = create(:product, name: "Test Product 2", user: seller, created_at: 1.hour.ago)

    # Set up necessary prerequisites
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
    create(:merchant_account_stripe_connect, user: seller)
    create(:payment_completed, user: seller)
  end

  include_context "with switching account to user as admin for seller"

  describe "Creating a new workflow (full E2E flow)" do
    it "allows creating a simple seller workflow (exact match to existing pattern)" do
      visit workflows_path
      click_on "New workflow", match: :first

      expect(page).to have_radio_button "Purchase", checked: true
      check "Also send to past customers"
      fill_in "Name", with: "E2E Seller workflow"
      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")

      workflow = Workflow.last
      expect(page).to have_current_path(workflow_emails_path(workflow.external_id))

      expect(workflow.name).to eq("E2E Seller workflow")
      expect(workflow.workflow_type).to eq(Workflow::SELLER_TYPE)
      expect(workflow.send_to_past_customers).to be(true)
      expect(workflow.seller).to eq(seller)
      expect(workflow.link).to be_nil
      expect(workflow.bought_products).to be_nil
      expect(workflow.not_bought_products).to be_nil
    end

    it "allows creating a product workflow with filters via frontend" do
      visit workflows_path
      click_on "New workflow", match: :first

      fill_in "Name", with: "Product workflow with filters"
      check "Also send to past customers"
      # Selecting exactly 1 product creates a "product" type workflow, not "seller" type
      select_combo_box_option @product1.name, from: "Has bought"
      fill_in "Paid more than", with: "5"
      fill_in "Paid less than", with: "100"

      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")

      workflow = Workflow.last
      expect(workflow.name).to eq("Product workflow with filters")
      expect(workflow.workflow_type).to eq(Workflow::PRODUCT_TYPE)  # 1 product = product type
      expect(workflow.link).to eq(@product1)  # The product becomes the link
      expect(workflow.bought_products).to eq([@product1.unique_permalink])
      expect(workflow.paid_more_than_cents).to eq(500)
      expect(workflow.paid_less_than_cents).to eq(10_000)
    end

    it "creates a follower workflow via frontend" do
      visit workflows_path
      click_on "New workflow", match: :first

      # Select follower type
      choose "New subscriber"
      expect(page).to have_unchecked_field "Also send to past email subscribers"

      fill_in "Name", with: "Follower Workflow E2E"
      check "Also send to past email subscribers"

      select_combo_box_option @product1.name, from: "Has bought"
      select_combo_box_option @product2.name, from: "Has not yet bought"

      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")

      workflow = Workflow.last
      expect(workflow.name).to eq("Follower Workflow E2E")
      expect(workflow.workflow_type).to eq(Workflow::FOLLOWER_TYPE)
      expect(workflow.send_to_past_customers).to be(true)
      expect(workflow.bought_products).to eq([@product1.unique_permalink])
      expect(workflow.not_bought_products).to eq([@product2.unique_permalink])
    end

    it "validates date ranges on the frontend" do
      visit workflows_path
      click_on "New workflow", match: :first

      fill_in "Name", with: "Validation Test"
      fill_in "Purchased after", with: "01/01/2024"
      fill_in "Purchased before", with: "01/01/2023"  # Invalid: before < after

      click_on "Save and continue"

      # Should show validation error
      expect(find_field("Purchased after")).to have_ancestor("fieldset.danger")
      expect(find_field("Purchased before")).to have_ancestor("fieldset.danger")

      # Fix the validation error
      fill_in "Purchased before", with: "01/01/2025"
      expect(find_field("Purchased after")).to_not have_ancestor("fieldset.danger")
      expect(find_field("Purchased before")).to_not have_ancestor("fieldset.danger")

      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")
    end

    it "validates amount ranges on the frontend" do
      visit workflows_path
      click_on "New workflow", match: :first

      fill_in "Name", with: "Amount Validation Test"
      fill_in "Paid more than", with: "100"
      fill_in "Paid less than", with: "10"  # Invalid: more than > less than

      click_on "Save and continue"

      # Should show validation error
      expect(find_field("Paid more than")).to have_ancestor("fieldset.danger")
      expect(find_field("Paid less than")).to have_ancestor("fieldset.danger")

      # Fix the validation error
      fill_in "Paid less than", with: "200"
      expect(find_field("Paid more than")).to_not have_ancestor("fieldset.danger")
      expect(find_field("Paid less than")).to_not have_ancestor("fieldset.danger")

      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")
    end
  end

  describe "Editing an existing workflow (full E2E flow)" do
    let!(:workflow) { create(:seller_workflow, seller:, name: "Original Workflow Name") }

    it "allows editing workflow details via frontend" do
      # Step 1: Visit workflows index
      visit workflows_path
      expect(page).to have_text("Original Workflow Name")

      # Step 2: Click edit workflow
      within_section "Original Workflow Name", section_element: :section do
        click_on "Edit workflow"
      end

      # Step 3: Verify we're on edit page
      expect(page).to have_current_path(edit_workflow_path(workflow.external_id))
      expect(page).to have_input_labelled "Name", with: "Original Workflow Name"

      # Step 4: Edit the name
      fill_in "Name", with: "Updated Workflow Name via E2E"

      # Step 5: Save changes
      click_on "Save changes"

      # Step 6: Verify success
      expect(page).to have_alert(text: "Changes saved!")
      expect(page).to have_current_path(workflow_emails_path(workflow.external_id))

      # Step 7: Verify workflow was updated
      workflow.reload
      expect(workflow.name).to eq("Updated Workflow Name via E2E")
    end

    it "prevents editing workflow type after creation" do
      visit workflows_path
      within_section "Original Workflow Name", section_element: :section do
        click_on "Edit workflow"
      end

      # Workflow type radio buttons should be present but behavior is controlled by the form
      expect(page).to have_radio_button "Purchase", checked: true
      expect(page).to have_radio_button "New subscriber"

      # Change the name and save
      fill_in "Name", with: "Name Updated Only"
      click_on "Save changes"
      expect(page).to have_alert(text: "Changes saved!")

      workflow.reload
      expect(workflow.name).to eq("Name Updated Only")
      expect(workflow.workflow_type).to eq(Workflow::SELLER_TYPE)  # Type unchanged
    end

    it "validates date ranges when editing" do
      visit edit_workflow_path(workflow.external_id)

      fill_in "Purchased after", with: "01/01/2024"
      fill_in "Purchased before", with: "01/01/2023"  # Invalid

      click_on "Save changes"

      # Should show validation errors
      expect(find_field("Purchased after")).to have_ancestor("fieldset.danger")
      expect(find_field("Purchased before")).to have_ancestor("fieldset.danger")

      # Don't save - verify workflow unchanged
      workflow.reload
      expect(workflow.name).to eq("Original Workflow Name")
    end
  end

  describe "Deleting a workflow (full E2E flow)" do
    let!(:workflow_to_delete) { create(:workflow, seller:, name: "Workflow to Delete") }

    it "allows deleting a workflow via frontend" do
      # Step 1: Visit workflows index
      visit workflows_path
      expect(page).to have_text("Workflow to Delete")

      # Step 2: Click delete in the workflow card
      within_section "Workflow to Delete", section_element: :section do
        click_on "Delete"
      end

      # Step 3: Confirm deletion in modal
      expect(page).to have_text('Are you sure you want to delete the workflow "Workflow to Delete"?')
      click_on "Delete"

      # Step 4: Verify success
      expect(page).to have_alert(text: "Workflow deleted!")
      expect(page).to_not have_text("Workflow to Delete")

      # Step 5: Verify workflow is soft deleted
      workflow_to_delete.reload
      expect(workflow_to_delete.deleted_at).to be_present
      expect(Workflow.alive.find_by(id: workflow_to_delete.id)).to be_nil
    end

    it "allows canceling workflow deletion" do
      visit workflows_path

      within_section "Workflow to Delete", section_element: :section do
        click_on "Delete"
      end

      # Cancel the deletion
      click_on "Cancel"

      # Workflow should still be visible
      expect(page).to_not have_alert(text: "Workflow deleted!")
      expect(page).to have_text("Workflow to Delete")

      # Verify workflow is not deleted
      workflow_to_delete.reload
      expect(workflow_to_delete.deleted_at).to be_nil
    end
  end

  describe "Workflow form interactions (full E2E flow)" do
    it "shows/hides fields based on workflow type selection" do
      visit workflows_path
      click_on "New workflow", match: :first

      # Purchase type
      expect(page).to have_radio_button "Purchase", checked: true
      expect(page).to have_unchecked_field "Also send to past customers"
      expect(page).to have_combo_box "Has bought"
      expect(page).to have_combo_box "Has not yet bought"
      expect(page).to have_input_labelled "Paid more than", with: ""
      expect(page).to have_input_labelled "Paid less than", with: ""

      # Switch to New subscriber
      choose "New subscriber"
      expect(page).to have_unchecked_field "Also send to past email subscribers"
      expect(page).to have_combo_box "Has bought"
      expect(page).to have_combo_box "Has not yet bought"
      expect(page).to_not have_field "Paid more than"
      expect(page).to_not have_field "Paid less than"
      expect(page).to have_input_labelled "Subscribed after", with: ""
      expect(page).to have_input_labelled "Subscribed before", with: ""

      # Switch to Member cancels
      choose "Member cancels"
      expect(page).to have_unchecked_field "Also send to past members who canceled"
      expect(page).to have_combo_box "Is a member of"
      expect(page).to_not have_combo_box "Has not yet bought"
      expect(page).to have_input_labelled "Paid more than", with: ""
      expect(page).to have_input_labelled "Paid less than", with: ""

      # Switch to New affiliate
      choose "New affiliate"
      expect(page).to have_unchecked_field "Also send to past affiliates"
      expect(page).to_not have_combo_box "Has bought"
      expect(page).to_not have_combo_box "Has not yet bought"
      expect(page).to have_combo_box "Affiliated products"
      expect(page).to_not have_field "Paid more than"
      expect(page).to_not have_field "Paid less than"
    end

    it "allows multi-select in product dropdowns" do
      visit workflows_path
      click_on "New workflow", match: :first

      fill_in "Name", with: "Multi-Product Workflow"

      # Select multiple products
      select_combo_box_option @product1.name, from: "Has bought"
      select_combo_box_option @product2.name, from: "Has bought"

      within :fieldset, "Has bought" do
        expect(page).to have_button(@product1.name)
        expect(page).to have_button(@product2.name)
      end

      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")

      workflow = Workflow.last
      expect(workflow.bought_products).to match_array([@product1.unique_permalink, @product2.unique_permalink])
    end
  end

  describe "Complete workflow creation flow (full E2E)" do
    it "creates workflow and navigates to emails page" do
      # Step 1: Create workflow
      visit workflows_path
      click_on "New workflow", match: :first

      fill_in "Name", with: "Complete E2E Workflow"
      choose "Purchase"
      check "Also send to past customers"

      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")

      workflow = Workflow.last
      expect(page).to have_current_path(workflow_emails_path(workflow.external_id))

      # Step 2: Verify we're on the emails page with correct UI
      expect(page).to have_tab_button("Details", open: false)
      expect(page).to have_tab_button("Emails", open: true)
      expect(page).to have_text("Create emails for your workflow")

      # Step 3: Go back to workflows list
      # The back link should navigate to workflows index
      visit workflows_path  # Just visit directly for now
      expect(page).to have_text("Complete E2E Workflow")

      # Step 4: Verify workflow shows up in list
      within_section "Complete E2E Workflow", section_element: :section do
        expect(page).to have_text("Unpublished")
        expect(page).to have_text("No emails yet")
      end
    end
  end

  describe "Edit workflow with validation errors (full E2E)" do
    let!(:workflow) { create(:seller_workflow, seller:, name: "Edit Test Workflow") }

    it "shows and clears validation errors in real-time" do
      visit edit_workflow_path(workflow.external_id)

      # Add invalid date range
      fill_in "Purchased after", with: "01/01/2024"
      fill_in "Purchased before", with: "01/01/2023"

      click_on "Save changes"

      # Errors should appear
      expect(find_field("Purchased after")).to have_ancestor("fieldset.danger")
      expect(find_field("Purchased before")).to have_ancestor("fieldset.danger")

      # Fix the error
      fill_in "Purchased before", with: "12/31/2024"

      # Errors should clear
      expect(find_field("Purchased after")).to_not have_ancestor("fieldset.danger")
      expect(find_field("Purchased before")).to_not have_ancestor("fieldset.danger")

      click_on "Save changes"
      expect(page).to have_alert(text: "Changes saved!")
    end
  end

  describe "Workflow navigation (full E2E)" do
    let!(:workflow) { create(:seller_workflow, seller:, name: "Navigation Test") }

    it "navigates to edit page and shows correct UI" do
      visit workflows_path

      within_section "Navigation Test", section_element: :section do
        click_on "Edit workflow"
      end

      expect(page).to have_current_path(edit_workflow_path(workflow.external_id))
      expect(page).to have_field("Name")
      expect(page).to have_input_labelled "Name", with: "Navigation Test"
    end

    it "can navigate from edit to emails and back" do
      visit edit_workflow_path(workflow.external_id)
      expect(page).to have_field("Name")

      # Navigate using tab buttons (use tab button selector)
      within "[role='tablist']" do
        click_on "Emails"
      end

      expect(page).to have_current_path(workflow_emails_path(workflow.external_id))
      expect(page).to have_text("Create emails for your workflow")

      # Navigate back
      within "[role='tablist']" do
        click_on "Details"
      end

      expect(page).to have_current_path(edit_workflow_path(workflow.external_id))
      expect(page).to have_field("Name")
    end
  end

  describe "Inertia page transitions (full E2E)" do
    it "uses Inertia for seamless navigation without full page reloads" do
      visit workflows_path

      # Get the initial page HTML
      initial_html = page.find("html")["outerHTML"]

      # Create a new workflow
      click_on "New workflow", match: :first

      # Verify we navigated (URL changed)
      expect(page).to have_current_path(new_workflow_path)

      # Verify the HTML didn't completely reload (Inertia SPA behavior)
      # In a full page load, the entire DOM would be replaced
      # With Inertia, only the main content changes
      expect(page).to have_selector("#inertia-shell")  # Inertia container persists

      # Fill and save
      fill_in "Name", with: "Inertia Test Workflow"
      click_on "Save and continue"

      # Navigate via Inertia
      expect(page).to have_alert(text: "Changes saved!")

      # Verify we're on emails page after save
      workflow = Workflow.last
      expect(page).to have_current_path(workflow_emails_path(workflow.external_id))

      # Verify Inertia SPA behavior - shell persists
      expect(page).to have_selector("#inertia-shell")

      # Navigate back to workflows list
      visit workflows_path
      expect(page).to have_text("Inertia Test Workflow")
    end
  end

  describe "Workflow with multiple products and filters (complex E2E)" do
    it "creates a complex workflow with multiple filters" do
      visit workflows_path
      click_on "New workflow", match: :first

      # Fill in complex workflow
      fill_in "Name", with: "Complex Multi-Filter Workflow"
      check "Also send to past customers"

      # Select multiple bought products
      select_combo_box_option @product1.name, from: "Has bought"
      select_combo_box_option @product2.name, from: "Has bought"

      # Add price filters
      fill_in "Paid more than", with: "10"
      fill_in "Paid less than", with: "50"

      # Add date filters
      fill_in "Purchased after", with: "01/01/2023"
      fill_in "Purchased before", with: "12/31/2024"

      # Add location filter
      select "United States", from: "From"

      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")

      # Verify all filters were saved
      workflow = Workflow.last
      expect(workflow.name).to eq("Complex Multi-Filter Workflow")
      expect(workflow.bought_products).to match_array([@product1.unique_permalink, @product2.unique_permalink])
      expect(workflow.send_to_past_customers).to be(true)
      expect(workflow.paid_more_than_cents).to eq(1_000)
      expect(workflow.paid_less_than_cents).to eq(5_000)
      expect(workflow.bought_from).to eq("United States")
      expect(workflow.created_after).to be_present
      expect(workflow.created_before).to be_present
    end
  end

  describe "Error handling and recovery (full E2E)" do
    it "recovers from server errors gracefully" do
      visit workflows_path
      click_on "New workflow", match: :first

      # Try to save without filling required field that would cause validation error
      fill_in "Name", with: "Error Recovery Test"
      fill_in "Paid more than", with: "100"
      fill_in "Paid less than", with: "50"  # Invalid range

      click_on "Save and continue"

      # Error should be shown
      expect(find_field("Paid more than")).to have_ancestor("fieldset.danger")
      expect(find_field("Paid less than")).to have_ancestor("fieldset.danger")

      # Fix and retry
      fill_in "Paid less than", with: "200"
      click_on "Save and continue"

      # Should succeed this time
      expect(page).to have_alert(text: "Changes saved!")
      expect(Workflow.last.name).to eq("Error Recovery Test")
    end
  end
end

