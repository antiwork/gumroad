# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/creator_dashboard_page"

describe("Workflows", js: true, type: :system) do
  include PostHelpers

  def find_email_row(name)
    find("[aria-label='Email'] h3", text: name, exact_text: true).ancestor("[aria-label='Email']")
  end

  def find_abandoned_cart_item(name)
    find("[role=listitem] h4", text: name, exact_text: true).ancestor("[role=listitem]")
  end

  def have_abandoned_cart_item(name)
    have_selector("[role=listitem] h4", text: name, exact_text: true)
  end

  let(:seller) { create(:named_seller) }

  before do
    @product = create(:product, name: "product name", user: seller, created_at: 2.hours.ago)
    @product2 = create(:product, name: "product 2 name", user: seller, created_at: 1.hour.ago)
    create(:purchase, link: @product)
    index_model_records(Purchase)

    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
    create(:merchant_account_stripe_connect, user: seller)
    create(:payment_completed, user: seller)
  end

  include_context "with switching account to user as admin for seller"

  it_behaves_like "creator dashboard page", "Workflows" do
    let(:path) { workflows_path }
  end

  describe "workflow list page" do
    it "shows the workflows" do
      # When there are no alive workflows
      deleted_workflow = create(:workflow, seller:, name: "Deleted workflow", deleted_at: Time.current)
      visit workflows_path
      expect(page).to_not have_text(deleted_workflow.name)
      expect(page).to have_text("Automate emails with ease.")

      # When there is an alive workflow that is not published and doesn't have any installments
      unpublished_workflow = create(:workflow, seller:, name: "Test workflow")
      visit workflows_path
      expect(page).to_not have_text("Automate emails with ease.")
      expect(page).to_not have_table(unpublished_workflow.name)
      within_section unpublished_workflow.name, section_element: :section do
        expect(page).to have_text("Unpublished")
        expect(page).to have_text("No emails yet, add one")
        expect(page).to have_link("add one", href: "/workflows/#{unpublished_workflow.external_id}/emails")
      end

      # When there is an alive workflow that is published and doesn't have any installments
      published_workflow = create(:audience_workflow, seller:, name: "Greet new customers", published_at: 1.day.ago)
      visit workflows_path
      expect(page).to_not have_table(published_workflow.name)
      within_section published_workflow.name, section_element: :section do
        expect(page).to have_text("Published")
        expect(page).to have_text("No emails yet, add one")
      end

      # When there is an alive workflow that is unpublished and have installments
      unpublished_workflow_installment1 = create(:installment, workflow: unpublished_workflow, name: "Unpublished legacy installment")
      create(:installment_rule, installment: unpublished_workflow_installment1, time_period: "day", delayed_delivery_time: 1.hour.to_i)
      unpublished_workflow_installment2 = create(:published_installment, workflow: unpublished_workflow, name: "Installment 2")
      create(:installment_rule, installment: unpublished_workflow_installment2, time_period: "hour", delayed_delivery_time: 1.day.to_i)
      unpublished_workflow_installment3 = create(:published_installment, workflow: unpublished_workflow, name: "Installment 3")
      create(:installment_rule, installment: unpublished_workflow_installment3, time_period: "hour", delayed_delivery_time: 2.hours.to_i)
      visit workflows_path
      within_table unpublished_workflow.name do
        expect(page).to have_text("Unpublished")
        expect(page).to have_table_row({ "Email" => unpublished_workflow_installment1.name })
        expect(page).to have_table_row({ "Email" => unpublished_workflow_installment2.name })
        expect(page).to_not have_table_row({ "Email" => unpublished_workflow_installment2.name, "Delay" => "24 Hours", "Sent" => "0", "Opens" => "0%", "Clicks" => "0" })
        expect(page).to have_table_row({ "Email" => unpublished_workflow_installment3.name })
        expect(page).to_not have_table_row({ "Email" => unpublished_workflow_installment3.name, "Delay" => "2 Hours", "Sent" => "0", "Opens" => "0%", "Clicks" => "0" })
      end

      # When there is an alive workflow that is published and have installments
      published_workflow_installment1 = create(:installment, workflow: published_workflow, name: "Unpublished legacy installment")
      create(:installment_rule, installment: published_workflow_installment1, time_period: "day", delayed_delivery_time: 1.hour.to_i)
      published_workflow_installment2 = create(:published_installment, workflow: published_workflow, name: "Installment 2")
      create(:installment_rule, installment: published_workflow_installment2, time_period: "hour", delayed_delivery_time: 1.day.to_i)
      published_workflow_installment3 = create(:published_installment, workflow: published_workflow, name: "Installment 3")
      create(:installment_rule, installment: published_workflow_installment3, time_period: "hour", delayed_delivery_time: 2.hours.to_i)
      visit workflows_path
      within_table published_workflow.name do
        expect(page).to have_text("Published")
        expect(page).to have_table_row({ "Email" => published_workflow_installment1.name })
        expect(page).to have_table_row({ "Email" => published_workflow_installment2.name, "Delay" => "24 Hours", "Sent" => "0", "Opens" => "0%", "Clicks" => "0" })
        expect(page).to have_table_row({ "Email" => published_workflow_installment3.name, "Delay" => "2 Hours", "Sent" => "0", "Opens" => "0%", "Clicks" => "0" })
      end

      # Deletes a workflow
      within_table published_workflow.name do
        click_on "Delete"
      end
      expect(page).to have_text(%Q(Are you sure you want to delete the workflow "#{published_workflow.name}"? This action cannot be undone.))
      click_on "Cancel"
      expect(page).to_not have_alert(text: "Workflow deleted!")
      expect(page).to have_text(published_workflow.name)
      within_table published_workflow.name do
        click_on "Delete"
      end
      expect do
        click_on "Delete"
        expect(page).to have_alert(text: "Workflow deleted!")
        expect(page).to_not have_text(published_workflow.name)
      end.to change { Workflow.alive.count }.by(-1)
       .and change { published_workflow.reload.deleted_at }.from(nil).to(be_within(5.seconds).of(DateTime.current))
    end
  end

  describe "new workflow scenario" do
    before do
      create(:payment_completed, user: seller)
    end

    it "performs validations" do
      visit workflows_path
      click_on "New workflow", match: :first

      expect(page).to have_radio_button "Purchase", checked: true
      click_on "Save and continue"
      expect(find_field("Name")).to have_ancestor("fieldset.danger")
      fill_in "Name", with: "A workflow"
      expect(find_field("Name")).to_not have_ancestor("fieldset.danger")
      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")
      workflow = Workflow.last
      expect(workflow.name).to eq("A workflow")

      edit_workflow_path = "/workflows/#{workflow.external_id}/edit"
      visit edit_workflow_path
      expect(page).to have_input_labelled "Name", with: "A workflow"
      fill_in "Paid more than", with: "10"
      fill_in "Paid less than", with: "1"
      click_on "Save changes"
      expect(find_field("Paid more than")).to have_ancestor("fieldset.danger")
      expect(find_field("Paid less than")).to have_ancestor("fieldset.danger")
      fill_in "Paid less than", with: "20"
      expect(find_field("Paid more than")).to_not have_ancestor("fieldset.danger")
      expect(find_field("Paid less than")).to_not have_ancestor("fieldset.danger")
      click_on "Save changes"
      expect(page).to have_alert(text: "Changes saved!")
      expect(workflow.reload.paid_more_than_cents).to eq(1_000)
      expect(workflow.paid_less_than_cents).to eq(2_000)

      visit edit_workflow_path
      expect(page).to have_input_labelled "Paid more than", with: "10"
      expect(page).to have_input_labelled "Paid less than", with: "20"
      fill_in "Purchased after", with: "01/01/2023"
      fill_in "Purchased before", with: "01/01/2022"
      click_on "Save changes"
      expect(find_field("Purchased after")).to have_ancestor("fieldset.danger")
      expect(find_field("Purchased before")).to have_ancestor("fieldset.danger")
      fill_in "Purchased before", with: "01/01/2024"
      expect(find_field("Purchased after")).to_not have_ancestor("fieldset.danger")
      expect(find_field("Purchased before")).to_not have_ancestor("fieldset.danger")
      click_on "Save changes"
      expect(page).to have_alert(text: "Changes saved!")
      timezone = ActiveSupport::TimeZone[workflow.seller.timezone]
      expect(workflow.reload.created_after).to eq(timezone.parse("2023-01-01").as_json)
      expect(workflow.created_before).to eq(timezone.parse("2024-01-01").end_of_day.as_json)

      visit edit_workflow_path
      expect(page).to have_input_labelled "Purchased after", with: "2023-01-01"
      expect(page).to have_input_labelled "Purchased before", with: "2024-01-01"
    end

    it "shows corresponding fields on choosing a trigger" do
      visit workflows_path
      click_on "New workflow", match: :first

      expect(page).to have_radio_button "Purchase", checked: true
      expect(page).to have_unchecked_field "Also send to past customers"
      expect(page).to have_combo_box "Has bought"
      expect(page).to have_combo_box "Has not yet bought"
      expect(page).to have_input_labelled "Paid more than", with: ""
      expect(page).to have_input_labelled "Paid less than", with: ""
      expect(page).to have_input_labelled "Purchased after", with: ""
      expect(page).to have_input_labelled "Purchased before", with: ""
      expect(page).to have_select "From", selected: "Anywhere"

      choose "New subscriber"
      expect(page).to have_unchecked_field "Also send to past email subscribers"
      expect(page).to have_combo_box "Has bought"
      expect(page).to have_combo_box "Has not yet bought"
      expect(page).to_not have_field "Paid more than"
      expect(page).to_not have_field "Paid less than"
      expect(page).to have_input_labelled "Subscribed after", with: ""
      expect(page).to have_input_labelled "Subscribed before", with: ""
      expect(page).to_not have_select "From"

      choose "Member cancels"
      expect(page).to have_unchecked_field "Also send to past members who canceled"
      expect(page).to have_combo_box "Is a member of"
      expect(page).to_not have_combo_box "Has not yet bought"
      expect(page).to have_input_labelled "Paid more than", with: ""
      expect(page).to have_input_labelled "Paid less than", with: ""
      expect(page).to have_input_labelled "Canceled after", with: ""
      expect(page).to have_input_labelled "Canceled before", with: ""
      expect(page).to have_select "From", selected: "Anywhere"

      choose "New affiliate"
      expect(page).to have_unchecked_field "Also send to past affiliates"
      expect(page).to_not have_combo_box "Has bought"
      expect(page).to_not have_combo_box "Has not yet bought"
      expect(page).to have_combo_box "Affiliated products"
      expect(page).to have_unchecked_field "All products"
      expect(page).to_not have_field "Paid more than"
      expect(page).to_not have_field "Paid less than"
      expect(page).to have_input_labelled "Affiliate after", with: ""
      expect(page).to have_input_labelled "Affiliate before", with: ""
      expect(page).to_not have_select "From"

      choose "Abandoned cart"
      expect(page).to_not have_field "Also send to past customers"
      expect(page).to have_combo_box "Has products in abandoned cart"
      expect(page).to have_combo_box "Does not have products in abandoned cart"
      expect(page).to_not have_field "Paid more than"
      expect(page).to_not have_field "Paid less than"
      expect(page).to_not have_field "Purchased after"
      expect(page).to_not have_field "Purchased before"
      expect(page).to_not have_select "From"
    end

    it "allows selecting or unselecting all affiliated products with a single click" do
      visit workflows_path
      click_on "New workflow", match: :first

      choose "New affiliate"
      expect(page).to have_unchecked_field "All products"
      find(:label, "Affiliated products").click
      expect(page).to have_combo_box "Affiliated products", options: ["product 2 name", "product name"]
      send_keys(:escape)
      check "All products"
      within :fieldset, "Affiliated products" do
        ["product 2 name", "product name"].each do |option|
          expect(page).to have_button(option)
        end
        click_on "product name"
        send_keys(:escape)
        expect(page).to have_button("product 2 name")
        expect(page).to_not have_button("product name")
        expect(page).to have_unchecked_field("All products")
      end
      find(:label, "Affiliated products").click
      expect(page).to have_combo_box "Affiliated products", options: ["product name"]
      select_combo_box_option "product name", from: "Affiliated products"
      expect(page).to have_checked_field("All products")
      uncheck "All products"
      within :fieldset, "Affiliated products" do
        ["product 2 name", "product name"].each do |option|
          expect(page).to_not have_button(option)
        end
      end
      find(:label, "Affiliated products").click
      expect(page).to have_combo_box "Affiliated products", options: ["product 2 name", "product name"]
    end

    it "doesn't include archived products in the product dropdowns" do
      @product.update!(archived: true) # Archived and has sales
      @product2.update!(archived: true) # Archived and has no sales
      create(:product, name: "My product", user: seller)

      visit workflows_path
      click_on "New workflow", match: :first

      find(:label, "Has bought").click
      expect(page).to have_combo_box "Has bought", options: ["My product"]
      send_keys(:escape)
      find(:label, "Has not yet bought").click
      expect(page).to have_combo_box "Has not yet bought", options: ["My product"]

      choose "New affiliate"
      expect(page).to have_unchecked_field "All products"
      find(:label, "Affiliated products").click
      expect(page).to have_combo_box "Affiliated products", options: ["My product"]
    end

    it "allows creating a follower workflow" do
      visit workflows_path
      click_on "New workflow", match: :first

      choose "New subscriber"
      check "Also send to past email subscribers"
      fill_in "Name", with: "New subscriber workflow"
      select_combo_box_option @product.name, from: "Has bought"
      select_combo_box_option @product2.name, from: "Has not yet bought"
      fill_in "Subscribed before", with: "01/01/2023"
      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")

      workflow = Workflow.last
      expect(workflow.name).to eq("New subscriber workflow")
      expect(workflow.workflow_type).to eq(Workflow::FOLLOWER_TYPE)
      expect(workflow.workflow_trigger).to be_nil
      expect(workflow.send_to_past_customers).to be(true)
      expect(workflow.seller).to eq(seller)
      expect(workflow.link).to be_nil
      expect(workflow.published_at).to be_nil
      expect(workflow.bought_products).to eq([@product.unique_permalink])
      expect(workflow.not_bought_products).to eq([@product2.unique_permalink])
      expect(workflow.bought_variants).to be_nil
      expect(workflow.not_bought_variants).to be_nil
      expect(workflow.created_after).to be_nil
      expect(workflow.created_before).to eq(ActiveSupport::TimeZone[seller.timezone].parse("2023-01-01").end_of_day.as_json)
      expect(workflow.bought_from).to be_nil
    end

    it "allows creating a seller workflow for all products" do
      visit workflows_path
      click_on "New workflow", match: :first

      expect(page).to have_radio_button "Purchase", checked: true
      check "Also send to past customers"
      fill_in "Name", with: "Seller workflow"
      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")

      workflow = Workflow.last
      expect(workflow.name).to eq("Seller workflow")
      expect(workflow.workflow_type).to eq(Workflow::SELLER_TYPE)
      expect(workflow.send_to_past_customers).to be(true)
      expect(workflow.workflow_trigger).to be_nil
      expect(workflow.seller).to eq(seller)
      expect(workflow.link).to be_nil
      expect(workflow.published_at).to be_nil
      expect(workflow.bought_products).to be_nil
      expect(workflow.not_bought_products).to be_nil
      expect(workflow.bought_variants).to be_nil
      expect(workflow.not_bought_variants).to be_nil
    end

    it "allows creating a seller workflow for multiple products" do
      visit workflows_path
      click_on "New workflow", match: :first

      expect(page).to have_radio_button "Purchase", checked: true
      fill_in "Name", with: "Seller workflow"
      select_combo_box_option @product.name, from: "Has bought"
      select_combo_box_option @product2.name, from: "Has bought"
      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")

      workflow = Workflow.last
      expect(workflow.name).to eq("Seller workflow")
      expect(workflow.workflow_type).to eq(Workflow::SELLER_TYPE)
      expect(workflow.send_to_past_customers).to be(false)
      expect(workflow.workflow_trigger).to be_nil
      expect(workflow.seller).to eq(seller)
      expect(workflow.link).to be_nil
      expect(workflow.published_at).to be_nil
      expect(workflow.bought_products).to match_array([@product.unique_permalink, @product2.unique_permalink])
      expect(workflow.not_bought_products).to be_nil
      expect(workflow.bought_variants).to be_nil
      expect(workflow.not_bought_variants).to be_nil
    end

    it "allows creating a product workflow" do
      variant_category = create(:variant_category, link: @product)
      create(:variant, variant_category:, name: "Version 1")
      create(:variant, variant_category:, name: "Version 2")

      visit workflows_path
      click_on "New workflow", match: :first

      expect(page).to have_radio_button "Purchase", checked: true
      check "Also send to past customers"
      fill_in "Name", with: "Product workflow"
      select_combo_box_option @product.name, from: "Has bought"
      select_combo_box_option @product2.name, from: "Has not yet bought"
      fill_in "Paid more than", with: "1"
      fill_in "Paid less than", with: "10"
      fill_in "Purchased after", with: "01/01/2023"
      select "Canada", from: "From"
      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")

      workflow = Workflow.last
      expect(workflow.name).to eq("Product workflow")
      expect(workflow.workflow_type).to eq(Workflow::PRODUCT_TYPE)
      expect(workflow.send_to_past_customers).to be(true)
      expect(workflow.workflow_trigger).to be_nil
      expect(workflow.seller).to eq(seller)
      expect(workflow.link).to eq(@product)
      expect(workflow.published_at).to be_nil
      expect(workflow.bought_products).to eq([@product.unique_permalink])
      expect(workflow.not_bought_products).to eq([@product2.unique_permalink])
      expect(workflow.bought_variants).to be_nil
      expect(workflow.not_bought_variants).to be_nil
      expect(workflow.paid_more_than_cents).to eq(100)
      expect(workflow.paid_less_than_cents).to eq(1_000)
      expect(workflow.created_after).to eq(ActiveSupport::TimeZone[seller.timezone].parse("2023-01-01").as_json)
      expect(workflow.created_before).to be_nil
      expect(workflow.bought_from).to eq("Canada")
    end

    it "allows creating a variant workflow" do
      variant_category = create(:variant_category, link: @product)
      _variant1 = create(:variant, variant_category:, name: "Version 1")
      variant2 = create(:variant, variant_category:, name: "Version 2")

      visit workflows_path
      click_on "New workflow", match: :first

      expect(page).to have_radio_button "Purchase", checked: true
      fill_in "Name", with: "Variant workflow"
      select_combo_box_option variant2.name, from: "Has bought"
      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")

      workflow = Workflow.last
      expect(workflow.name).to eq("Variant workflow")
      expect(workflow.workflow_type).to eq(Workflow::VARIANT_TYPE)
      expect(workflow.workflow_trigger).to be_nil
      expect(workflow.seller).to eq(seller)
      expect(workflow.link).to eq(@product)
      expect(workflow.published_at).to be_nil
      expect(workflow.bought_products).to be_nil
      expect(workflow.not_bought_products).to be_nil
      expect(workflow.bought_variants).to eq([variant2.external_id])
      expect(workflow.not_bought_variants).to be_nil
      expect(workflow.base_variant).to eq(variant2)
    end

    it "allows creating a variant workflow for physical product using sku" do
      product = create(:physical_product, user: seller)
      variant_category1 = create(:variant_category, link: product, title: "Brand")
      create(:variant, variant_category: variant_category1, name: "Nike")
      create(:variant, variant_category: variant_category1, name: "Adidas")
      variant_category2 = create(:variant_category, link: product, title: "Style")
      create(:variant, variant_category: variant_category2, name: "Running")
      create(:variant, variant_category: variant_category2, name: "Walking")
      Product::SkusUpdaterService.new(product:).perform

      visit workflows_path
      click_on "New workflow", match: :first

      expect(page).to have_radio_button "Purchase", checked: true
      fill_in "Name", with: "Variant workflow"
      select_combo_box_option "Adidas - Walking", from: "Has bought"
      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")

      sku = Sku.find_by_name("Adidas - Walking")
      workflow = Workflow.last
      expect(workflow.name).to eq("Variant workflow")
      expect(workflow.workflow_type).to eq(Workflow::VARIANT_TYPE)
      expect(workflow.workflow_trigger).to be_nil
      expect(workflow.send_to_past_customers).to be(false)
      expect(workflow.seller).to eq(seller)
      expect(workflow.link).to eq(product)
      expect(workflow.published_at).to be_nil
      expect(workflow.bought_products).to be_nil
      expect(workflow.not_bought_products).to be_nil
      expect(workflow.bought_variants).to eq([sku.external_id])
      expect(workflow.not_bought_variants).to be_nil
      expect(workflow.base_variant).to eq(sku)
    end

    it "allows creating a member cancelation workflow of product type" do
      visit workflows_path
      click_on "New workflow", match: :first

      choose "Member cancels"
      check "Also send to past members who canceled"
      fill_in "Name", with: "Member cancelation workflow"
      select_combo_box_option @product.name, from: "Is a member of"
      fill_in "Paid more than", with: "1"
      fill_in "Paid less than", with: "10"
      fill_in "Canceled after", with: "01/01/2023"
      select "Canada", from: "From"
      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")

      workflow = Workflow.last
      expect(workflow.name).to eq("Member cancelation workflow")
      expect(workflow.workflow_type).to eq(Workflow::PRODUCT_TYPE)
      expect(workflow.workflow_trigger).to eq("member_cancellation")
      expect(workflow.send_to_past_customers).to be(true)
      expect(workflow.seller).to eq(seller)
      expect(workflow.link).to eq(@product)
      expect(workflow.published_at).to be_nil
      expect(workflow.bought_products).to eq([@product.unique_permalink])
      expect(workflow.not_bought_products).to be_nil
      expect(workflow.bought_variants).to be_nil
      expect(workflow.not_bought_variants).to be_nil
      expect(workflow.paid_more_than_cents).to eq(100)
      expect(workflow.paid_less_than_cents).to eq(1_000)
      expect(workflow.created_after).to eq(ActiveSupport::TimeZone[seller.timezone].parse("2023-01-01").as_json)
      expect(workflow.created_before).to be_nil
      expect(workflow.bought_from).to eq("Canada")
    end

    it "allows creating a member cancelation workflow of variant type" do
      variant_category = create(:variant_category, link: @product)
      _variant1 = create(:variant, variant_category:, name: "Version 1")
      variant2 = create(:variant, variant_category:, name: "Version 2")

      visit workflows_path
      click_on "New workflow", match: :first

      choose "Member cancels"
      fill_in "Name", with: "Member cancelation workflow"
      select_combo_box_option variant2.name, from: "Is a member of"
      fill_in "Paid more than", with: "1"
      fill_in "Paid less than", with: "10"
      fill_in "Canceled after", with: "01/01/2023"
      select "Canada", from: "From"
      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")

      workflow = Workflow.last
      expect(workflow.name).to eq("Member cancelation workflow")
      expect(workflow.workflow_type).to eq(Workflow::VARIANT_TYPE)
      expect(workflow.workflow_trigger).to eq("member_cancellation")
      expect(workflow.send_to_past_customers).to be(false)
      expect(workflow.seller).to eq(seller)
      expect(workflow.link).to eq(@product)
      expect(workflow.published_at).to be_nil
      expect(workflow.bought_products).to be_nil
      expect(workflow.not_bought_products).to be_nil
      expect(workflow.bought_variants).to eq([variant2.external_id])
      expect(workflow.base_variant).to eq(variant2)
      expect(workflow.not_bought_variants).to be_nil
      expect(workflow.paid_more_than_cents).to eq(100)
      expect(workflow.paid_less_than_cents).to eq(1_000)
      expect(workflow.created_after).to eq(ActiveSupport::TimeZone[seller.timezone].parse("2023-01-01").as_json)
      expect(workflow.created_before).to be_nil
      expect(workflow.bought_from).to eq("Canada")
    end

    it "allows creating a new affiliate workflow" do
      visit workflows_path
      click_on "New workflow", match: :first

      choose "New affiliate"
      check "Also send to past affiliates"
      fill_in "Name", with: "New affiliate workflow"
      select_combo_box_option @product.name, from: "Affiliated products"
      fill_in "Affiliate after", with: "01/01/2023"
      fill_in "Affiliate before", with: "01/01/2024"
      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")

      workflow = Workflow.last
      expect(workflow.name).to eq("New affiliate workflow")
      expect(workflow.workflow_type).to eq(Workflow::AFFILIATE_TYPE)
      expect(workflow.workflow_trigger).to be_nil
      expect(workflow.send_to_past_customers).to be(true)
      expect(workflow.seller).to eq(seller)
      expect(workflow.link).to be_nil
      expect(workflow.published_at).to be_nil
      expect(workflow.bought_products).to be_nil
      expect(workflow.not_bought_products).to be_nil
      expect(workflow.bought_variants).to be_nil
      expect(workflow.not_bought_variants).to be_nil
      expect(workflow.affiliate_products).to eq([@product.unique_permalink])
      expect(workflow.created_after).to eq(ActiveSupport::TimeZone[seller.timezone].parse("2023-01-01").as_json)
      expect(workflow.created_before).to eq(ActiveSupport::TimeZone[seller.timezone].parse("2024-01-01").end_of_day.as_json)
    end

    it "allows creating an abandoned cart workflow with a ready-made installment" do
      product3 = create(:product, name: "Product 3", user: seller)
      variant_category = create(:variant_category, link: product3)
      create(:variant, variant_category:, name: "Version 1")
      product3_version2 = create(:variant, variant_category:, name: "Version 2")
      product4 = create(:product, name: "Product 4", user: seller)
      product5 = create(:product, name: "Product 5", user: seller)

      visit workflows_path

      click_on "New workflow", match: :first

      choose "Abandoned cart"
      fill_in "Name", with: "Abandoned cart workflow"
      select_combo_box_option @product.name, from: "Has products in abandoned cart"
      select_combo_box_option "Product 3 — Version 2", from: "Has products in abandoned cart"
      select_combo_box_option product4.name, from: "Has products in abandoned cart"
      select_combo_box_option product5.name, from: "Has products in abandoned cart"
      select_combo_box_option @product2.name, from: "Does not have products in abandoned cart"
      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")

      workflow = Workflow.last
      expect(workflow.name).to eq("Abandoned cart workflow")
      expect(workflow.workflow_type).to eq(Workflow::ABANDONED_CART_TYPE)
      expect(workflow.workflow_trigger).to be_nil
      expect(workflow.seller).to eq(seller)
      expect(workflow.link).to be_nil
      expect(workflow.published_at).to be_nil
      expect(workflow.bought_products).to eq([@product.unique_permalink, product4.unique_permalink, product5.unique_permalink])
      expect(workflow.not_bought_products).to eq([@product2.unique_permalink])
      expect(workflow.bought_variants).to eq([product3_version2.external_id])
      expect(workflow.not_bought_variants).to be_nil
      expect(workflow.created_after).to be_nil
      expect(workflow.created_before).to be_nil
      expect(workflow.bought_from).to be_nil

      installment = workflow.installments.alive.sole
      expect(installment.name).to eq("You left something in your cart")
      expect(installment.message).to eq(%Q(<p>When you're ready to buy, <a href="#{checkout_index_url(host: UrlService.domain_with_protocol)}" target="_blank" rel="noopener noreferrer nofollow">complete checking out</a>.</p><product-list-placeholder />))
      expect(installment.installment_type).to eq(Installment::ABANDONED_CART_TYPE)
      expect(installment.installment_rule.time_period).to eq("hour")
      expect(installment.installment_rule.delayed_delivery_time).to eq(24.hour)

      expect(page).to have_current_path("/workflows/#{workflow.external_id}/emails")
      within find_email_row("You left something in your cart") do
        expect(page).to have_field("Subject", with: "You left something in your cart")
        expect(page).to_not have_field("Duration")
        expect(page).to_not have_select("Period")
        expect(page).to_not have_button("Edit")
        expect(page).to_not have_button("Delete")
        within find("[aria-label='Email message']") do
          expect(page).to have_text("When you're ready to buy, complete checking out", normalize_ws: true)
          expect(page).to have_link("complete checking out", href: checkout_index_url(host: UrlService.domain_with_protocol))
          find_abandoned_cart_item(@product.name).hover
          expect(page).to have_text("This cannot be deleted")
          within find_abandoned_cart_item(@product.name) do
            expect(page).to have_link(@product.name, href: @product.long_url)
            expect(page).to have_link(seller.name, href: seller.subdomain_with_protocol)
          end
          expect(page).to_not have_abandoned_cart_item(@product2.name)
          expect(page).to have_abandoned_cart_item(product3.name)
          expect(page).to have_abandoned_cart_item(product4.name)
          expect(page).to_not have_abandoned_cart_item(product5.name)
          expect(page).to have_link("Complete checkout", href: checkout_index_url(host: UrlService.domain_with_protocol))
        end
      end
      within find("[aria-label=Preview]") do
        within_section "You left something in your cart" do
          expect(page).to have_text("24 hours after cart abandonment")
          expect(page).to have_text("When you're ready to buy, complete checking out", normalize_ws: true)
          expect(page).to have_link("complete checking out", href: checkout_index_url(host: UrlService.domain_with_protocol))
          find_abandoned_cart_item(@product.name).hover
          expect(page).to_not have_text("This cannot be deleted")
          within find_abandoned_cart_item(@product.name) do
            expect(page).to have_link(@product.name, href: @product.long_url)
            expect(page).to have_link(seller.name, href: seller.subdomain_with_protocol)
          end
          expect(page).to_not have_abandoned_cart_item(@product2.name)
          expect(page).to have_abandoned_cart_item(product3.name)
          expect(page).to have_abandoned_cart_item(product4.name)
          expect(page).to_not have_abandoned_cart_item(product5.name)
          expect(page).to have_link("Complete checkout", href: checkout_index_url(host: UrlService.domain_with_protocol))
          expect(page).to have_text("548 Market St, San Francisco, CA 94104-5401, USA")
          expect(page).to have_text("Powered by")
        end
      end
      within find_email_row("You left something in your cart") do
        within find("[aria-label='Email message']") do
          click_on "and 1 more product"
          expect(page).to have_abandoned_cart_item(product5.name)
          expect(page).to_not have_text("more product")
        end
      end
      within find("[aria-label=Preview]") do
        expect(page).to have_abandoned_cart_item(product5.name)
        expect(page).to_not have_text("more product")
      end
      within find_email_row("You left something in your cart") do
        message_editor = find("[aria-label='Email message']")
        rich_text_editor_select_all message_editor
        message_editor.base.send_keys("New description line")
        within message_editor do
          expect(page).to have_text("New description line")
          expect(page).to_not have_text("When you're ready to buy, complete checking out.")
          expect(page).to have_abandoned_cart_item(@product.name)
          expect(page).to have_abandoned_cart_item(product3.name)
          expect(page).to have_abandoned_cart_item(product4.name)
          expect(page).to have_abandoned_cart_item(product5.name)
        end
      end
      within find("[aria-label=Preview]") do
        expect(page).to have_text("New description line")
        expect(page).to_not have_text("When you're ready to buy, complete checking out.")
        expect(page).to have_abandoned_cart_item(@product.name)
        expect(page).to have_abandoned_cart_item(product3.name)
        expect(page).to have_abandoned_cart_item(product4.name)
        expect(page).to have_abandoned_cart_item(product5.name)
      end
      sleep 1 # Wait for the editor to update
      expect(page).to_not have_alert(text: "Changes saved!")
      click_on "Save"
      expect(page).to have_alert(text: "Changes saved!")
      expect(installment.reload.message).to eq("<p>New description line</p><product-list-placeholder></product-list-placeholder>")
      refresh
      within find_email_row("You left something in your cart") do
        within find("[aria-label='Email message']") do
          expect(page).to have_text("New description line")
          expect(page).to have_abandoned_cart_item(@product.name)
          expect(page).to have_abandoned_cart_item(product3.name)
          expect(page).to have_abandoned_cart_item(product4.name)
          expect(page).to_not have_abandoned_cart_item(product5.name)
          expect(page).to have_button("and 1 more product")
        end
      end
    end

    it "shows the empty product list placeholder in the email editor when there are no abandoned cart products to display" do
      visit workflows_path
      click_on "New workflow", match: :first

      choose "Abandoned cart"
      fill_in "Name", with: "Abandoned cart workflow"
      select_combo_box_option @product.name, from: "Has products in abandoned cart"
      click_on "Save and continue"
      expect(page).to have_alert(text: "Changes saved!")
      expect(page).to have_current_path("/workflows/#{Workflow.last.external_id}/emails")
      within find_email_row("You left something in your cart") do
        within find("[aria-label='Email message']") do
          expect(page).to have_abandoned_cart_item(@product.name)
          expect(page).to_not have_text("No products selected")
          expect(page).to_not have_text("Add a product to have it show up here")
        end
      end

      seller.products.find_each(&:mark_deleted!)
      refresh
      within find_email_row("You left something in your cart") do
        within find("[aria-label='Email message']") do
          expect(page).to_not have_abandoned_cart_item(@product.name)
          expect(page).to have_text("Add a product to have it show up here")
          expect(page).to_not have_text("No products selected")
        end
      end

      click_on "Publish"
      expect(page).to have_alert(text: "Workflow published!")
      refresh
      within find_email_row("You left something in your cart") do
        within find("[aria-label='Email message']") do
          expect(page).to_not have_abandoned_cart_item(@product.name)
          expect(page).to_not have_text("Add a product to have it show up here")
          expect(page).to have_text("No products selected")
        end
      end

      workflow = Workflow.last
      workflow.update!(bought_products: nil)
      refresh
      within find_email_row("You left something in your cart") do
        within find("[aria-label='Email message']") do
          expect(page).to_not have_abandoned_cart_item(@product.name)
          expect(page).to have_text("Add a product to have it show up here")
          expect(page).to_not have_text("No products selected")
          click_on "Add a product", match: :first
        end
      end
      expect(page).to have_text("Publish your first product")
    end

    context "when the user isn't eligible for abandoned cart workflows" do
      before do
        allow_any_instance_of(User).to receive(:eligible_for_abandoned_cart_workflows?).and_return(false)
      end

      it "disables the abandoned cart trigger and renders a tooltip" do
        visit workflows_path
        click_on "New workflow", match: :first

        button = find(:radio_button, "Abandoned cart", disabled: true)
        button.hover
        expect(button).to have_tooltip(text: "You must have at least one completed payout to create abandoned cart workflows")
      end
    end
  end

  describe "edit workflow scenario" do
    let(:seller_timezone) { ActiveSupport::TimeZone[seller.timezone] }
    let(:created_after) { seller_timezone.parse("2023-01-01").as_json }
    let(:created_before) { seller_timezone.parse("2024-01-01").end_of_day.as_json }

    context "when a workflow was not published before" do
      it "allows editing a legacy audience workflow" do
        workflow = create(:audience_workflow, name: "Legacy audience workflow", seller:, not_bought_products: [@product.unique_permalink], created_after:, created_before:)

        visit workflows_path
        within_section "Legacy audience workflow", section_element: :section do
          click_on "Edit workflow"
        end

        expect(page).to have_current_path("/workflows/#{workflow.external_id}/edit")
        expect(page).to have_tab_button("Details", open: true)
        expect(page).to have_tab_button("Emails", open: false)
        expect(page).to have_input_labelled "Name", with: "Legacy audience workflow"
        expect(page).to have_radio_button "Audience", checked: true
        expect(page).to have_unchecked_field "Also send to past customers"
        expect(page).to_not have_combo_box "Has bought"
        expect(page).to have_combo_box "Has not yet bought"
        within :fieldset, "Has not yet bought" do
          expect(page).to have_button("product name")
        end
        expect(page).to_not have_field "Paid more than"
        expect(page).to_not have_field "Paid less than"
        expect(page).to have_input_labelled "Purchased after", with: "2023-01-01"
        expect(page).to have_input_labelled "Purchased before", with: "2024-01-01"
        expect(page).to_not have_select "From"

        fill_in "Name", with: "Legacy audience workflow (edited)"
        check "Also send to past customers"
        within :fieldset, "Has not yet bought" do
          click_on "product name"
          send_keys(:escape)
        end
        select_combo_box_option @product2.name, from: "Has not yet bought"
        fill_in "Purchased after", with: "01/01/2024"
        fill_in "Purchased before", with: "01/01/2025"
        click_on "Save changes"
        expect(page).to have_alert(text: "Changes saved!")
        expect(page).to have_current_path("/workflows/#{workflow.external_id}/emails")
        expect(page).to have_tab_button("Details", open: false)
        expect(page).to have_tab_button("Emails", open: true)

        workflow.reload
        expect(workflow.name).to eq("Legacy audience workflow (edited)")
        expect(workflow.workflow_type).to eq(Workflow::AUDIENCE_TYPE)
        expect(workflow.send_to_past_customers).to be(true)
        expect(workflow.workflow_trigger).to be_nil
        expect(workflow.seller).to eq(seller)
        expect(workflow.link).to be_nil
        expect(workflow.published_at).to be_nil
        expect(workflow.bought_products).to be_nil
        expect(workflow.not_bought_products).to eq([@product2.unique_permalink])
        expect(workflow.bought_variants).to be_nil
        expect(workflow.not_bought_variants).to be_nil
        expect(workflow.created_after).to eq(seller_timezone.parse("2024-01-01").as_json)
        expect(workflow.created_before).to eq(seller_timezone.parse("2025-01-01").end_of_day.as_json)
        expect(workflow.bought_from).to be_nil
      end

      it "allows editing a seller workflow" do
        workflow = create(:seller_workflow, name: "Seller workflow", seller:, bought_products: [@product.unique_permalink, @product2.unique_permalink], paid_more_than_cents: 100, created_after:, created_before:, bought_from: "Canada", send_to_past_customers: true)

        visit workflows_path
        within_section "Seller workflow", section_element: :section do
          click_on "Edit workflow"
        end

        expect(page).to have_input_labelled "Name", with: "Seller workflow"
        expect(page).to have_radio_button "Purchase", checked: true
        expect(page).to have_checked_field "Also send to past customers"
        within :fieldset, "Has bought" do
          expect(page).to have_button("product name")
          expect(page).to have_button("product 2 name")
        end
        expect(page).to have_combo_box "Has not yet bought"
        expect(page).to have_input_labelled "Paid more than", with: "1"
        expect(page).to have_input_labelled "Paid less than", with: ""
        expect(page).to have_input_labelled "Purchased after", with: "2023-01-01"
        expect(page).to have_input_labelled "Purchased before", with: "2024-01-01"
        expect(page).to have_select "From", selected: "Canada"

        fill_in "Name", with: "Seller workflow (edited)"
        uncheck "Also send to past customers"
        fill_in "Paid more than", with: "12"
        fill_in "Paid less than", with: "20"
        fill_in "Purchased after", with: "01/01/2024"
        fill_in "Purchased before", with: "01/01/2025"
        select "United States", from: "From"
        click_on "Save changes"
        expect(page).to have_alert(text: "Changes saved!")

        workflow.reload
        expect(workflow.name).to eq("Seller workflow (edited)")
        expect(workflow.workflow_type).to eq(Workflow::SELLER_TYPE)
        expect(workflow.send_to_past_customers).to be(false)
        expect(workflow.workflow_trigger).to be_nil
        expect(workflow.seller).to eq(seller)
        expect(workflow.link).to be_nil
        expect(workflow.published_at).to be_nil
        expect(workflow.bought_products).to match_array([@product.unique_permalink, @product2.unique_permalink])
        expect(workflow.not_bought_products).to be_nil
        expect(workflow.bought_variants).to be_nil
        expect(workflow.not_bought_variants).to be_nil
        expect(workflow.paid_more_than_cents).to eq(1_200)
        expect(workflow.paid_less_than_cents).to eq(2_000)
        expect(workflow.created_after).to eq(seller_timezone.parse("2024-01-01").as_json)
        expect(workflow.created_before).to eq(seller_timezone.parse("2025-01-01").end_of_day.as_json)
        expect(workflow.bought_from).to eq("United States")
      end

      it "allows editing a product workflow" do
        workflow = create(:product_workflow, name: "Product workflow", seller:, link: @product, bought_products: [@product.unique_permalink], not_bought_products: [@product2.unique_permalink], paid_more_than_cents: 100, created_after:, created_before:, bought_from: "Canada", send_to_past_customers: true)

        visit workflows_path
        within_section "Product workflow", section_element: :section do
          click_on "Edit workflow"
        end

        expect(page).to have_input_labelled "Name", with: "Product workflow"
        expect(page).to have_radio_button "Purchase", checked: true
        expect(page).to have_checked_field "Also send to past customers"
        within :fieldset, "Has bought" do
          expect(page).to have_button("product name")
        end
        within :fieldset, "Has not yet bought" do
          expect(page).to have_button("product 2 name")
        end
        expect(page).to have_input_labelled "Paid more than", with: "1"
        expect(page).to have_input_labelled "Paid less than", with: ""
        expect(page).to have_input_labelled "Purchased after", with: "2023-01-01"
        expect(page).to have_input_labelled "Purchased before", with: "2024-01-01"
        expect(page).to have_select "From", selected: "Canada"

        fill_in "Name", with: "Product workflow (edited)"
        uncheck "Also send to past customers"
        within :fieldset, "Has bought" do
          click_on "product name"
          send_keys(:escape)
        end
        select_combo_box_option "product 2 name", from: "Has bought"
        within :fieldset, "Has not yet bought" do
          click_on "product 2 name"
          send_keys(:escape)
        end
        select_combo_box_option "product name", from: "Has not yet bought"
        fill_in "Paid more than", with: ""
        fill_in "Paid less than", with: "20"
        fill_in "Purchased before", with: "01/01/2025"
        select "United States", from: "From"
        click_on "Save changes"
        expect(page).to have_alert(text: "Changes saved!")

        workflow.reload
        expect(workflow.name).to eq("Product workflow (edited)")
        expect(workflow.workflow_type).to eq(Workflow::PRODUCT_TYPE)
        expect(workflow.send_to_past_customers).to be(false)
        expect(workflow.workflow_trigger).to be_nil
        expect(workflow.seller).to eq(seller)
        expect(workflow.link).to eq(@product2)
        expect(workflow.published_at).to be_nil
        expect(workflow.bought_products).to match_array([@product2.unique_permalink])
        expect(workflow.not_bought_products).to match_array([@product.unique_permalink])
        expect(workflow.bought_variants).to be_nil
        expect(workflow.not_bought_variants).to be_nil
        expect(workflow.paid_more_than_cents).to be_nil
        expect(workflow.paid_less_than_cents).to eq(2_000)
        expect(workflow.created_after).to eq(seller_timezone.parse("2023-01-01").as_json)
        expect(workflow.created_before).to eq(seller_timezone.parse("2025-01-01").end_of_day.as_json)
        expect(workflow.bought_from).to eq("United States")
      end

      it "allows editing a variant workflow" do
        variant_category = create(:variant_category, link: @product)
        variant1 = create(:variant, variant_category:, name: "Version 1")
        variant2 = create(:variant, variant_category:, name: "Version 2")
        workflow = create(:variant_workflow, name: "Variant workflow", seller:, link: @product, base_variant: variant2, paid_more_than_cents: 100, created_before:, bought_from: "Canada")

        visit workflows_path
        within_section "Variant workflow", section_element: :section do
          click_on "Edit workflow"
        end

        expect(page).to have_input_labelled "Name", with: "Variant workflow"
        expect(page).to have_radio_button "Purchase", checked: true
        expect(page).to have_unchecked_field "Also send to past customers"
        within :fieldset, "Has bought" do
          expect(page).to have_button("Version 2")
        end
        expect(page).to have_combo_box "Has not yet bought"
        expect(page).to have_input_labelled "Paid more than", with: "1"
        expect(page).to have_input_labelled "Paid less than", with: ""
        expect(page).to have_input_labelled "Purchased after", with: ""
        expect(page).to have_input_labelled "Purchased before", with: "2024-01-01"
        expect(page).to have_select "From", selected: "Canada"

        fill_in "Name", with: "Variant workflow (edited)"
        check "Also send to past customers"
        within :fieldset, "Has bought" do
          click_on "Version 2"
          send_keys(:escape)
        end
        select_combo_box_option "Version 1", from: "Has bought"
        select_combo_box_option "Version 2", from: "Has not yet bought"
        fill_in "Paid more than", with: ""
        fill_in "Paid less than", with: "20"
        fill_in "Purchased after", with: "01/01/2024"
        fill_in "Purchased before", with: "01/01/2025"
        select "United States", from: "From"
        click_on "Save changes"
        expect(page).to have_alert(text: "Changes saved!")

        workflow.reload
        expect(workflow.name).to eq("Variant workflow (edited)")
        expect(workflow.workflow_type).to eq(Workflow::VARIANT_TYPE)
        expect(workflow.send_to_past_customers).to be(true)
        expect(workflow.workflow_trigger).to be_nil
        expect(workflow.seller).to eq(seller)
        expect(workflow.link).to eq(@product)
        expect(workflow.published_at).to be_nil
        expect(workflow.bought_products).to be_nil
        expect(workflow.not_bought_products).to be_nil
        expect(workflow.bought_variants).to match_array([variant1.external_id])
        expect(workflow.not_bought_variants).to match_array([variant2.external_id])
        expect(workflow.base_variant).to eq(variant1)
        expect(workflow.paid_more_than_cents).to be_nil
        expect(workflow.paid_less_than_cents).to eq(2_000)
        expect(workflow.created_after).to eq(seller_timezone.parse("2024-01-01").as_json)
        expect(workflow.created_before).to eq(seller_timezone.parse("2025-01-01").end_of_day.as_json)
        expect(workflow.bought_from).to eq("United States")
      end

      it "allows editing a follower workflow" do
        workflow = create(:follower_workflow, name: "Follower workflow", seller:, bought_products: [@product.unique_permalink], created_after:, created_before:, send_to_past_customers: true)

        visit workflows_path
        within_section "Follower workflow", section_element: :section do
          click_on "Edit workflow"
        end

        expect(page).to have_input_labelled "Name", with: "Follower workflow"
        expect(page).to have_radio_button "New subscriber", checked: true
        expect(page).to have_checked_field "Also send to past email subscribers"
        within :fieldset, "Has bought" do
          expect(page).to have_button("product name")
        end
        expect(page).to have_combo_box "Has not yet bought"
        expect(page).to_not have_field "Paid more than"
        expect(page).to_not have_field "Paid less than"
        expect(page).to have_input_labelled "Subscribed after", with: "2023-01-01"
        expect(page).to have_input_labelled "Subscribed before", with: "2024-01-01"
        expect(page).to_not have_select "From"

        fill_in "Name", with: "Follower workflow (edited)"
        uncheck "Also send to past email subscribers"
        within :fieldset, "Has bought" do
          click_on "product name"
          send_keys(:escape)
        end
        select_combo_box_option "product 2 name", from: "Has bought"
        fill_in "Subscribed before", with: "01/01/2025"
        click_on "Save changes"
        expect(page).to have_alert(text: "Changes saved!")

        workflow.reload
        expect(workflow.name).to eq("Follower workflow (edited)")
        expect(workflow.workflow_type).to eq(Workflow::FOLLOWER_TYPE)
        expect(workflow.send_to_past_customers).to be(false)
        expect(workflow.workflow_trigger).to be_nil
        expect(workflow.seller).to eq(seller)
        expect(workflow.link).to be_nil
        expect(workflow.published_at).to be_nil
        expect(workflow.bought_products).to match_array([@product2.unique_permalink])
        expect(workflow.not_bought_products).to be_nil
        expect(workflow.bought_variants).to be_nil
        expect(workflow.not_bought_variants).to be_nil
        expect(workflow.paid_more_than_cents).to be_nil
        expect(workflow.paid_less_than_cents).to be_nil
        expect(workflow.created_after).to eq(seller_timezone.parse("2023-01-01").as_json)
        expect(workflow.created_before).to eq(seller_timezone.parse("2025-01-01").end_of_day.as_json)
        expect(workflow.bought_from).to be_nil
      end

      it "allows editing a member cancelation workflow" do
        workflow = create(:product_workflow, name: "Member cancelation workflow", seller:, link: @product, workflow_trigger: "member_cancellation", bought_products: [@product.unique_permalink], bought_from: "Canada", send_to_past_customers: true)

        visit workflows_path
        within_section "Member cancelation workflow", section_element: :section do
          click_on "Edit workflow"
        end

        expect(page).to have_input_labelled "Name", with: "Member cancelation workflow"
        expect(page).to have_radio_button "Member cancels", checked: true
        expect(page).to have_checked_field "Also send to past members who canceled"
        within :fieldset, "Is a member of" do
          expect(page).to have_button("product name")
        end
        expect(page).to_not have_combo_box "Has not yet bought"
        expect(page).to have_input_labelled "Paid more than", with: ""
        expect(page).to have_input_labelled "Paid less than", with: ""
        expect(page).to have_input_labelled "Canceled after", with: ""
        expect(page).to have_input_labelled "Canceled before", with: ""
        expect(page).to have_select "From", selected: "Canada"

        fill_in "Name", with: "Member cancelation workflow (edited)"
        uncheck "Also send to past members who canceled"
        within :fieldset, "Is a member of" do
          click_on "product name"
          send_keys(:escape)
        end
        select_combo_box_option "product 2 name", from: "Is a member of"
        fill_in "Paid more than", with: "1"
        fill_in "Paid less than", with: "10"
        fill_in "Canceled after", with: "01/01/2024"
        fill_in "Canceled before", with: "01/01/2025"
        select "United States", from: "From"
        click_on "Save changes"
        expect(page).to have_alert(text: "Changes saved!")

        workflow.reload
        expect(workflow.name).to eq("Member cancelation workflow (edited)")
        expect(workflow.workflow_type).to eq(Workflow::PRODUCT_TYPE)
        expect(workflow.send_to_past_customers).to be(false)
        expect(workflow.workflow_trigger).to eq("member_cancellation")
        expect(workflow.seller).to eq(seller)
        expect(workflow.link).to eq(@product2)
        expect(workflow.published_at).to be_nil
        expect(workflow.bought_products).to match_array([@product2.unique_permalink])
        expect(workflow.not_bought_products).to be_nil
        expect(workflow.bought_variants).to be_nil
        expect(workflow.not_bought_variants).to be_nil
        expect(workflow.paid_more_than_cents).to eq(100)
        expect(workflow.paid_less_than_cents).to eq(1_000)
        expect(workflow.created_after).to eq(seller_timezone.parse("2024-01-01").as_json)
        expect(workflow.created_before).to eq(seller_timezone.parse("2025-01-01").end_of_day.as_json)
        expect(workflow.bought_from).to eq("United States")
      end

      it "allows editing a new affiliate workflow" do
        workflow = create(:affiliate_workflow, name: "New affiliate workflow", seller:, affiliate_products: [@product2.unique_permalink], created_after:, send_to_past_customers: true)

        visit workflows_path
        within_section "New affiliate workflow", section_element: :section do
          click_on "Edit workflow"
        end

        expect(page).to have_input_labelled "Name", with: "New affiliate workflow"
        expect(page).to have_radio_button "New affiliate", checked: true
        expect(page).to have_checked_field "Also send to past affiliates"
        within :fieldset, "Affiliated products" do
          expect(page).to have_button("product 2 name")
        end
        expect(page).to_not have_combo_box "Has bought"
        expect(page).to_not have_combo_box "Has not yet bought"
        expect(page).to_not have_field "Paid more than"
        expect(page).to_not have_field "Paid less than"
        expect(page).to have_input_labelled "Affiliate after", with: "2023-01-01"
        expect(page).to have_input_labelled "Affiliate before", with: ""
        expect(page).to_not have_select "From"

        fill_in "Name", with: "New affiliate workflow (edited)"
        uncheck "Also send to past affiliates"
        within :fieldset, "Affiliated products" do
          click_on "product 2 name"
          send_keys(:escape)
        end
        select_combo_box_option "product name", from: "Affiliated products"
        fill_in "Affiliate after", with: "01/01/2024"
        fill_in "Affiliate before", with: "01/01/2025"
        click_on "Save changes"
        expect(page).to have_alert(text: "Changes saved!")

        workflow.reload
        expect(workflow.name).to eq("New affiliate workflow (edited)")
        expect(workflow.workflow_type).to eq(Workflow::AFFILIATE_TYPE)
        expect(workflow.send_to_past_customers).to be(false)
        expect(workflow.workflow_trigger).to be_nil
        expect(workflow.seller).to eq(seller)
        expect(workflow.link).to be_nil
        expect(workflow.published_at).to be_nil
        expect(workflow.bought_products).to be_nil
        expect(workflow.not_bought_products).to be_nil
        expect(workflow.bought_variants).to be_nil
        expect(workflow.not_bought_variants).to be_nil
        expect(workflow.affiliate_products).to match_array([@product.unique_permalink])
        expect(workflow.created_after).to eq(seller_timezone.parse("2024-01-01").as_json)
        expect(workflow.created_before).to eq(seller_timezone.parse("2025-01-01").end_of_day.as_json)
        expect(workflow.bought_from).to be_nil
      end

      it "allows changing the workflow type" do
        workflow = create(:follower_workflow, name: "Follower workflow", seller:, link: @product, bought_products: [@product.unique_permalink], not_bought_products: [@product2.unique_permalink])

        visit workflows_path
        within_section "Follower workflow", section_element: :section do
          click_on "Edit workflow"
        end

        expect(page).to have_radio_button "New subscriber", checked: true
        choose "Member cancels"
        fill_in "Name", with: "Member cancelation workflow"

        expect do
          click_on "Save changes"
          expect(page).to have_alert(text: "Changes saved!")
        end.to change { workflow.reload.workflow_type }.from(Workflow::FOLLOWER_TYPE).to(Workflow::PRODUCT_TYPE)
           .and change { workflow.workflow_trigger }.from(nil).to("member_cancellation")
           .and change { workflow.name }.from("Follower workflow").to("Member cancelation workflow")
           .and change { workflow.not_bought_products }.from([@product2.unique_permalink]).to(nil)
        expect(workflow.bought_products).to eq([@product.unique_permalink])

        click_on "Back"
        within_section "Member cancelation workflow", section_element: :section do
          click_on "Edit workflow"
        end

        expect(page).to have_input_labelled "Name", with: "Member cancelation workflow"
        expect(page).to have_radio_button "Member cancels", checked: true
        within :fieldset, "Is a member of" do
          expect(page).to have_button("product name")
        end
      end

      it "allows saving and publishing a workflow" do
        workflow = create(:product_workflow, name: "Product workflow", seller:, link: @product, bought_products: [@product.unique_permalink], not_bought_products: [@product2.unique_permalink], paid_more_than_cents: 100, created_after:, created_before:, bought_from: "Canada", send_to_past_customers: false)
        visit workflows_path
        installment = create(:workflow_installment, workflow:)

        expect_any_instance_of(Workflow).to receive(:schedule_installment).with(installment)

        within_section "Product workflow", section_element: :section do
          click_on "Edit workflow"
        end

        fill_in "Name", with: "My workflow (edited)"
        within :fieldset, "Has bought" do
          click_on "product name"
          send_keys(:escape)
        end
        select_combo_box_option "product 2 name", from: "Has bought"
        within :fieldset, "Has not yet bought" do
          click_on "product 2 name"
          send_keys(:escape)
        end
        select_combo_box_option "product name", from: "Has not yet bought"
        fill_in "Paid more than", with: ""
        fill_in "Paid less than", with: "20"
        fill_in "Purchased before", with: "01/01/2025"
        select "United States", from: "From"
        select_disclosure "Publish" do
          check "Also send to past customers"
          click_on "Publish now"
        end
        expect(page).to have_alert(text: "Workflow published!")

        expect(page).to_not have_disclosure("Publish")
        expect(page).to have_button("Unpublish")
        expect(page).to have_input_labelled "Name", with: "My workflow (edited)"
        expect(page).to have_radio_button "Purchase", checked: true, disabled: true
        expect(page).to have_radio_button "New subscriber", disabled: true
        expect(page).to have_radio_button "Member cancels", disabled: true
        expect(page).to have_radio_button "New affiliate", disabled: true
        expect(page).to_not have_field "Also send to past customers"
        expect(page).to have_field "Paid more than", with: "", disabled: true
        expect(page).to have_field "Paid less than", with: "20", disabled: true
        expect(page).to have_field "Purchased after", with: "2023-01-01", disabled: true
        expect(page).to have_field "Purchased before", with: "2025-01-01", disabled: true
        expect(page).to have_select "From", selected: "United States", disabled: true

        workflow.reload
        expect(workflow.name).to eq("My workflow (edited)")
        expect(workflow.workflow_type).to eq(Workflow::PRODUCT_TYPE)
        expect(workflow.send_to_past_customers).to be(true)
        expect(workflow.workflow_trigger).to be_nil
        expect(workflow.seller).to eq(seller)
        expect(workflow.link).to eq(@product2)
        expect(workflow.published_at).to be_within(10.seconds).of(Time.current)
        expect(workflow.first_published_at).to eq(workflow.published_at)
        expect(workflow.bought_products).to match_array([@product2.unique_permalink])
        expect(workflow.not_bought_products).to match_array([@product.unique_permalink])
        expect(workflow.bought_variants).to be_nil
        expect(workflow.not_bought_variants).to be_nil
        expect(workflow.paid_more_than_cents).to be_nil
        expect(workflow.paid_less_than_cents).to eq(2_000)
        expect(workflow.created_after).to eq(seller_timezone.parse("2023-01-01").as_json)
        expect(workflow.created_before).to eq(seller_timezone.parse("2025-01-01").end_of_day.as_json)
        expect(workflow.bought_from).to eq("United States")
        expect(installment.reload.published_at).to eq(workflow.published_at)
        expect(installment.installment_type).to eq(Installment::PRODUCT_TYPE)
        expect(installment.json_data).to eq(workflow.json_data)
        expect(installment.seller_id).to eq(workflow.seller_id)
        expect(installment.link_id).to eq(workflow.link_id)
        expect(installment.base_variant_id).to eq(workflow.base_variant_id)
        expect(installment.is_for_new_customers_of_workflow).to eq(!workflow.send_to_past_customers)

        fill_in "Name", with: "My workflow (edited again)"
        click_on "Unpublish"
        expect(page).to have_alert(text: "Unpublished!")
        expect(page).to_not have_button("Unpublish")
        expect(page).to_not have_disclosure("Publish")
        expect(page).to have_input_labelled "Name", with: "My workflow (edited again)"
        expect(page).to have_radio_button "Purchase", checked: true, disabled: true
        expect(page).to_not have_field "Also send to past customers"
        expect(workflow.reload.published_at).to be_nil
        expect(workflow.name).to eq("My workflow (edited again)")
        expect(workflow.first_published_at).to be_present
        expect(installment.reload.published_at).to be_nil
      end
    end

    it "shows an error when publishing a workflow when the seller is not eligible to send emails" do
      workflow = create(:product_workflow, name: "Product workflow", seller:, link: @product, bought_products: [@product.unique_permalink], not_bought_products: [@product2.unique_permalink], paid_more_than_cents: 100, created_after:, created_before:, bought_from: "Canada", send_to_past_customers: false)
      visit workflows_path
      create(:workflow_installment, workflow:)

      expect_any_instance_of(Workflow).to_not receive(:schedule_installment)
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE - 1)

      within_section "Product workflow", section_element: :section do
        click_on "Edit workflow"
      end

      fill_in "Name", with: "My workflow (edited)"
      select_disclosure "Publish" do
        click_on "Publish now"
      end
      expect(page).to have_alert(text: "You cannot publish a workflow until you have made at least $100 in total earnings and received a payout")
      expect(workflow.reload.published_at).to be_nil
      expect(workflow.name).to eq("Product workflow")
    end

    it "keeps previously selected product options as selected that are archived now but does not allow unselecting and selecting them again" do
      workflow = create(:product_workflow, name: "Product workflow", seller:, link: @product, bought_products: [@product.unique_permalink], not_bought_products: [@product2.unique_permalink], affiliate_products: [@product.unique_permalink])
      create(:workflow_installment, workflow:)

      @product.update!(archived: true) # Archived and has sales
      @product2.update!(archived: true) # Archived and has no sales
      create(:product, name: "My product", user: seller)

      visit workflows_path
      within_table "Product workflow" do
        click_on "Edit workflow"
      end

      find(:label, "Has bought").click
      expect(page).to have_combo_box "Has bought", options: ["My product", "product name"]
      click_on "product name"
      expect(page).to have_combo_box "Has bought", options: ["My product"]
      send_keys(:escape)

      find(:label, "Has not yet bought").click
      click_on @product2.unique_permalink
      find(:label, "Has not yet bought").click
      expect(page).to have_combo_box "Has not yet bought", options: ["My product"]
      send_keys(:escape)

      choose "New affiliate"
      expect(page).to have_unchecked_field "All products"
      find(:label, "Affiliated products").click
      expect(page).to have_combo_box "Affiliated products", options: ["My product", "product name"]
      click_on "product name"
      expect(page).to have_combo_box "Affiliated products", options: ["My product"]
    end

    context "when a workflow was previously published" do
      it "allows editing only the workflow name" do
        workflow = create(:product_workflow, name: "Product workflow", seller:, link: @product, bought_products: [@product.unique_permalink], not_bought_products: [@product2.unique_permalink], paid_more_than_cents: 100, created_after:, created_before:, bought_from: "Canada", send_to_past_customers: true, published_at: 2.days.ago, first_published_at: 2.days.ago)

        visit workflows_path
        within_section "Product workflow", section_element: :section do
          click_on "Edit workflow"
        end

        expect(page).to have_button("Unpublish")
        expect(page).to have_input_labelled "Name", with: "Product workflow"
        expect(page).to have_radio_button "Purchase", checked: true, disabled: true
        expect(page).to have_radio_button "New subscriber", disabled: true
        expect(page).to have_radio_button "Member cancels", disabled: true
        expect(page).to have_radio_button "New affiliate", disabled: true
        expect(page).to_not have_checked_field "Also send to past customers"
        expect(page).to have_field "Paid more than", with: "1", disabled: true
        expect(page).to have_field "Paid less than", with: "", disabled: true
        expect(page).to have_field "Purchased after", with: "2023-01-01", disabled: true
        expect(page).to have_field "Purchased before", with: "2024-01-01", disabled: true
        expect(page).to have_select "From", selected: "Canada", disabled: true

        fill_in "Name", with: "Product workflow (edited)"

        expect do
          expect do
            click_on "Save changes"
            expect(page).to have_alert(text: "Changes saved!")
          end.to change { workflow.reload.name }.from("Product workflow").to("Product workflow (edited)")
        end.to_not change { workflow.workflow_type }.from(Workflow::PRODUCT_TYPE)

        expect(workflow.send_to_past_customers).to be(true)
        expect(workflow.workflow_trigger).to be_nil
        expect(workflow.seller).to eq(seller)
        expect(workflow.link).to eq(@product)
        expect(workflow.published_at).to be_within(1.minute).of(2.days.ago)
        expect(workflow.first_published_at).to be_within(1.minute).of(2.days.ago)
        expect(workflow.bought_products).to match_array([@product.unique_permalink])
        expect(workflow.not_bought_products).to match_array([@product2.unique_permalink])
        expect(workflow.bought_variants).to be_nil
        expect(workflow.not_bought_variants).to be_nil
        expect(workflow.paid_more_than_cents).to eq(100)
        expect(workflow.paid_less_than_cents).to be(nil)
        expect(workflow.created_after).to eq(seller_timezone.parse("2023-01-01").as_json)
        expect(workflow.created_before).to eq(seller_timezone.parse("2024-01-01").end_of_day.as_json)
        expect(workflow.bought_from).to eq("Canada")
      end
    end
  end

  describe "saving emails" do
    def have_email_row(name)
      have_selector("[aria-label='Email'] h3", text: name, exact_text: true)
    end

    def have_file_row(name)
      have_selector("[aria-label=Files] [role=listitem] h4", text: name, exact_text: true)
    end

    def find_file_row(name)
      find("[aria-label=Files] [role=listitem] h4", text: name, exact_text: true).ancestor("[role=listitem]")
    end

    before do
      @workflow = create(:workflow, seller:, workflow_type: "seller")
      @workflow.bought_products = [@product.unique_permalink, @product2.unique_permalink]
      @workflow.save!
    end

    it "allows creating a new email for a workflow" do
      visit workflows_path

      within_section @workflow.name, section_element: :section do
        click_on "add one"
      end

      expect(page).to have_current_path("/workflows/#{@workflow.external_id}/emails")
      expect(page).to have_tab_button("Emails", open: true)
      within_section "Create emails for your workflow" do
        click_on "Create email"
      end
      within find_email_row("Untitled") do
        expect(page).to have_field("Subject", with: "")
        expect(page).to have_field("Duration", with: "0")
        expect(page).to have_select("Period", selected: "hours after purchase")
        fill_in "Duration", with: "1"
        select "day after purchase", from: "Period"
        fill_in "Subject", with: "Thank you!"
        message_editor = find("[aria-label='Email message']")
        set_rich_text_editor_input(message_editor, to_text: "An important message")
        select_disclosure "Insert" do
          click_on "Button"
        end
      end
      within_modal do
        fill_in "Enter text", with: "Click me"
        fill_in "Enter URL", with: "https://example.com/button"
        click_on "Add button"
      end
      within find_email_row("Thank you!") do
        page.attach_file(file_fixture("test.jpg")) do
          click_on "Insert image"
        end
      end
      expect(page).to have_button("Save changes", disabled: true)
      # Wait for the image to be uploaded
      expect(page).to have_button("Save changes", disabled: false)

      expect(page).to_not have_email_row("Untitled")
      within find_email_row("Thank you!") do
        page.attach_file("Attach files", file_fixture("test.mp4"), visible: false)
        expect(page).to have_unchecked_field("Disable file downloads (stream only)")
        within find_file_row("test") do
          click_on "Edit"

          page.attach_file("Add subtitles", Rails.root.join("spec/support/fixtures/sample.srt"), visible: false)

          expect(page).to have_file_row("sample")
        end
      end

      click_on "Add email"
      within find_email_row("Untitled") do
        fill_in "Duration", with: "2"
        select "hours after purchase", from: "Period"
        fill_in "Subject", with: "Here's a gift for you!"
        message_editor = find("[aria-label='Email message']")
        set_rich_text_editor_input(message_editor, to_text: "You're lucky!")
      end
      within find("[aria-label=Preview]") do
        within_section "Thank you!" do
          expect(page).to have_text("1 day after purchase")
          expect(page).to have_text("An important message")
          expect(page).to have_link("Click me", href: "https://example.com/button")
          expect(page).to have_selector("img")
          expect(page).to have_text("View content")
          expect(page).to have_text("548 Market St, San Francisco, CA 94104-5401, USA")
          expect(page).to have_text("Powered by")
        end
        within_section "Here's a gift for you!" do
          expect(page).to have_text("2 hours after purchase")
          expect(page).to have_text("You're lucky!")
        end
      end
      expect(page).to have_button("Save changes", disabled: false)
      click_on "Save changes"
      expect(page).to have_alert(text: "Changes saved!")

      expect(@workflow.installments.alive.count).to eq(2)
      installment1 = @workflow.installments.alive.find_by(name: "Thank you!")
      expect(installment1.message).to include("<p>An important message</p>")
      expect(installment1.message).to have_link("Click me", href: "https://example.com/button")
      expect(installment1.message).to include(%{<img src="#{AWS_S3_ENDPOINT}/#{S3_BUCKET}})
      expect(installment1.installment_rule.delayed_delivery_time).to eq(86_400)
      expect(installment1.installment_rule.time_period).to eq("day")
      expect(installment1.has_stream_only_files?).to be(false)
      expect(installment1.product_files.alive.count).to eq(1)
      expect(installment1.product_files.alive.first.filegroup).to eq("video")
      expect(installment1.product_files.alive.first.name_displayable).to eq("test")
      expect(installment1.product_files.alive.first.stream_only?).to be(false)
      expect(installment1.product_files.alive.first.subtitle_files.alive.count).to eq(1)
      expect(installment1.product_files.alive.first.subtitle_files.alive.first.url).to include("sample.srt")
      expect(installment1.product_files.alive.first.subtitle_files.alive.first.language).to include("English")
      installment2 = @workflow.installments.alive.find_by(name: "Here's a gift for you!")
      expect(installment2.message).to include("<p>You're lucky!</p>")
      expect(installment2.installment_rule.delayed_delivery_time).to eq(7_200)
      expect(installment2.installment_rule.time_period).to eq("hour")
      expect(installment2.product_files.alive.count).to eq(0)

      refresh

      within find_email_row("Here's a gift for you!") do
        click_on "Delete"
      end
      within_modal "Delete email?" do
        expect(page).to have_text("Are you sure you want to delete the email \"Here's a gift for you!\"? This action cannot be undone.")
        click_on "Delete"
      end
      expect(page).to_not have_email_row("Here's a gift for you!")
      click_on "Add email"
      within find_email_row("Untitled") do
        fill_in "Duration", with: "0"
        select "hours after purchase", from: "Period"
        fill_in "Subject", with: "Sneak peek of my new book"
        message_editor = find("[aria-label='Email message']")
        set_rich_text_editor_input(message_editor, to_text: "Why I wrote this book?")
      end
      within find_email_row("Thank you!") do
        click_on "Edit"
        check "Disable file downloads (stream only)"
      end
      within find("[aria-label=Preview]") do
        within_section "Thank you!" do
          expect(page).to have_text("1 day after purchase")
          expect(page).to have_text("An important message")
          expect(page).to have_selector("img")
        end
        within_section "Sneak peek of my new book" do
          expect(page).to have_text("0 hours after purchase")
          expect(page).to have_text("Why I wrote this book?")
        end
        expect(page).to_not have_section("Here's a gift for you!")
      end

      within find_email_row("Thank you!") do
        click_on "Preview Email"
      end
      expect(page).to have_button("Save changes", disabled: true)
      expect(page).to have_alert(text: "A preview has been sent to your email.")

      expect(@workflow.installments.alive.count).to eq(2)
      installment1 = Installment.find(installment1.id) # reloading does not clear the product files cache
      expect(installment1.reload.alive?).to be(true)
      expect(installment1.has_stream_only_files?).to be(true)
      expect(installment1.product_files.alive.first.stream_only?).to be(true)
      expect(installment2.reload.alive?).to be(false)
      installment3 = @workflow.installments.alive.find_by(name: "Sneak peek of my new book")
      expect(installment3.message).to include("<p>Why I wrote this book?</p>")
      expect(installment3.installment_rule.delayed_delivery_time).to eq(0)
      expect(installment3.installment_rule.time_period).to eq("hour")
      expect(installment3.has_stream_only_files?).to be(false)

      click_on "Back"
      within_table @workflow.name do
        expect(page).to have_table_row({ "Email" => "Thank you!" })
        expect(page).to have_table_row({ "Email" => "Sneak peek of my new book" })
        expect(page).to_not have_table_row({ "Email" => "Here's a gift for you!" })
      end
    end

    it "allows saving and publishing workflow emails" do
      expect_any_instance_of(Workflow).to receive(:schedule_installment).with(kind_of(Installment))

      visit workflows_path

      expect(@workflow.reload.published_at).to be_nil

      within_section @workflow.name, section_element: :section do
        click_on "add one"
      end

      within_section "Create emails for your workflow" do
        click_on "Create email"
      end
      within find_email_row("Untitled") do
        fill_in "Duration", with: "1"
        select "hour after purchase", from: "Period"
        fill_in "Subject", with: "Thank you!"
        message_editor = find("[aria-label='Email message']")
        set_rich_text_editor_input(message_editor, to_text: "An important message")
      end
      select_disclosure "Publish" do
        check "Also send to past customers"
        click_on "Publish now"
      end
      expect(page).to have_alert(text: "Workflow published!")

      expect(page).to_not have_disclosure("Publish")
      expect(page).to have_button("Unpublish")
      expect(@workflow.reload.published_at).to be_present
      expect(@workflow.first_published_at).to eq(@workflow.published_at)
      expect(@workflow.send_to_past_customers).to be(true)
      expect(@workflow.installments.alive.count).to eq(1)
      expect(@workflow.installments.alive.first.published_at).to eq(@workflow.published_at)
      expect(@workflow.installments.alive.first.name).to eq("Thank you!")

      within find_email_row("Thank you!") do
        fill_in "Subject", with: "Thank you! (edited)"
      end
      click_on "Unpublish"
      expect(page).to have_alert(text: "Unpublished!")
      expect(page).to_not have_button("Unpublish")
      expect(page).to_not have_disclosure("Publish")
      expect(@workflow.reload.published_at).to be_nil
      expect(@workflow.first_published_at).to be_present
      expect(@workflow.installments.alive.count).to eq(1)
      expect(@workflow.installments.alive.first.published_at).to be_nil
      expect(@workflow.installments.alive.first.name).to eq("Thank you! (edited)")
    end
  end
end
