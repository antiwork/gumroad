# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::Users::PurchasesController do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  before do
    @admin_user = create(:admin_user, email: "admin@example.com")
    sign_in @admin_user
  end

  describe "GET #index" do
    let(:user) { create(:user) }
    let(:seller) { create(:user) }
    let(:product1) { create(:product, user: seller, name: "Amazing Course") }
    let(:product2) { create(:product, user: seller, name: "Great Ebook") }

    before do
      @purchase1 = create(:purchase, link: product1, purchaser: user, email: user.email, purchase_state: "successful")
      @purchase2 = create(:purchase, link: product2, purchaser: user, email: user.email, purchase_state: "successful")
    end

    it "displays user's purchase history" do
      get :index, params: { user_id: user.id }

      expect(response).to be_successful
      expect(response.body).to have_text("Purchase history for #{user.display_name}")
      expect(response.body).to have_text(product1.name)
      expect(response.body).to have_text(product2.name)
    end

    it "filters purchases by product title when search term provided" do
      get :index, params: { user_id: user.id, product_title: "Amazing" }

      expect(response).to be_successful
      expect(response.body).to have_text(product1.name)
      expect(response.body).not_to have_text(product2.name)
    end

    it "shows empty state when no purchases match search" do
      get :index, params: { user_id: user.id, product_title: "Nonexistent" }

      expect(response).to be_successful
      expect(response.body).to have_text('No purchases found matching "Nonexistent"')
    end

    it "shows empty state when user has no purchases" do
      user_without_purchases = create(:user)

      get :index, params: { user_id: user_without_purchases.id }

      expect(response).to be_successful
      expect(response.body).to have_text("This user has no purchase history.")
    end

    it "paginates results when user has many purchases" do
      user_with_purchases = create(:user)
      purchases = []

      # Create purchases with distinct timestamps to ensure predictable ordering
      30.times do |i|
        product = create(:product, user: seller, name: "Product #{i}")
        purchases << create(:purchase,
                            link: product,
                            purchaser: user_with_purchases,
                            email: user_with_purchases.email,
                            purchase_state: "successful",
                            created_at: i.seconds.ago)
      end

      get :index, params: { user_id: user_with_purchases.id }

      expect(response).to be_successful
      expect(response.body).to have_selector(".pagination")

      # Since purchases are ordered by created_at desc, most recent (Product 0) should be first
      # Page 1 should show Product 0 through Product 24 (25 items)
      (0..24).each do |i|
        expect(response.body).to have_text("Product #{i}")
      end
      # Product 25 through Product 29 should not be visible on page 1
      (25..29).each do |i|
        expect(response.body).not_to have_text("Product #{i}")
      end
    end

    it "assigns correct instance variables" do
      get :index, params: { user_id: user.id, product_title: "Amazing" }

      expect(assigns(:user)).to eq(user)
      expect(assigns(:purchases)).to contain_exactly(@purchase1)
      expect(assigns(:search_query)).to eq("Amazing")
      expect(assigns(:title)).to eq("Purchase history for #{user.display_name}")
    end

    it "handles purchases with deleted products gracefully" do
      # Create a purchase normally first
      product_to_delete = create(:product, user: seller, name: "Product to be deleted")
      purchase_with_deleted_product = create(:purchase,
                                             link: product_to_delete,
                                             purchaser: user,
                                             email: user.email,
                                             purchase_state: "successful"
      )

      # Simulate the product being deleted by setting link to nil
      purchase_with_deleted_product.update_column(:link_id, nil)

      get :index, params: { user_id: user.id }

      expect(response).to be_successful
      expect(response.body).to have_text("(Product deleted)")
    end
  end
end
