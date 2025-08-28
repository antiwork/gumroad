# frozen_string_literal: true

describe CreatorHomePresenter do
  let(:admin_for_seller) { create(:user, username: "adminforseller") }
  let(:marketing_for_seller) { create(:user, username: "marketingforseller") }
  let(:support_for_seller) { create(:user, username: "supportforseller") }
  let(:seller) { create(:user, created_at: 60.days.ago) }
  let(:pundit_user) { SellerContext.new(user: admin_for_seller, seller:) }
  let(:presenter) { described_class.new(pundit_user) }

  around do |example|
    travel_to Time.utc(2022, 5, 17) do
      example.run
    end
  end

  before do
    create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
    create(:team_membership, user: marketing_for_seller, seller:, role: TeamMembership::ROLE_MARKETING)
    create(:team_membership, user: support_for_seller, seller:, role: TeamMembership::ROLE_SUPPORT)
  end

  describe "#creator_home_props" do
    it "deduces creator name from payout info" do
      expect(presenter.creator_home_props[:name]).to match("")

      create(:user_compliance_info, user: seller)
      expect(presenter.creator_home_props[:name]).to match("Chuck")
    end

    it "when creator has made a sale" do
      expect(presenter.creator_home_props[:has_sale]).to eq(false)

      create(:purchase, :from_seller, seller:)
      expect(presenter.creator_home_props[:has_sale]).to eq(true)
    end

    it "includes initial user getting started stats" do
      expect(presenter.creator_home_props[:getting_started_stats]).to match(
        {
          "customized_profile" => false,
          "first_email" => false,
          "first_follower" => false,
          "first_payout" => true,
          "first_product" => false,
          "first_sale" => false,
          "purchased_small_bets" => false,
        }
      )
    end

    it "doesn't consider workflow installments for first_email" do
      create(:installment, seller:, workflow_id: 1)
      expect(presenter.creator_home_props[:getting_started_stats]["first_email"]).to eq(false)
    end

    it "doesn't consider bundle product purchases for first_sale" do
      create(:purchase, :from_seller, seller:, is_bundle_product_purchase: true)
      expect(presenter.creator_home_props[:getting_started_stats]["first_sale"]).to eq(false)
    end

    it "includes updated user getting started stats" do
      seller.update!(name: "Gumbo")
      create(:post, seller:)
      create(:active_follower, user: seller)
      create(:purchase, :from_seller, seller:)
      create(:payment_completed, user: seller)

      expect(presenter.creator_home_props[:getting_started_stats]).to match(
        {
          "customized_profile" => true,
          "first_email" => true,
          "first_follower" => true,
          "first_payout" => true,
          "first_product" => true,
          "first_sale" => true,
          "purchased_small_bets" => false,
        }
      )
    end

    it "includes product data", :sidekiq_inline, :elasticsearch_wait_for_refresh  do
      recreate_model_index(Purchase)

      product1 = create(:product, user: seller)
      product2 = create(:product, user: seller)

      create(:purchase, link: product1, price_cents: 100, created_at: 30.days.ago)
      create(:purchase, link: product2, price_cents: 500, created_at: Time.current)
      create(:purchase, link: product2, price_cents: 1500, created_at: 6.days.ago)

      expect(presenter.creator_home_props[:sales]).to match(
        [
          {
            "id" => product2.unique_permalink,
            "name" => "The Works of Edgar Gumstein",
            "thumbnail" => nil,
            "revenue" => 2000.0,
            "sales" => 2,
            "visits" => 0,
            "today" => 500,
            "last_7" => 2000,
            "last_30" => 2000,
          },
          {
            "id" => product1.unique_permalink,
            "name" => "The Works of Edgar Gumstein",
            "thumbnail" => nil,
            "sales" => 1,
            "revenue" => 100.0,
            "visits" => 0,
            "today" => 0,
            "last_7" => 0,
            "last_30" => 100,
          },
        ]
      )
    end

    it "excludes soft-deleted thumbnails from product data" do
      # TODO(tech debt): Remove the top-level travel_to.
      travel_back

      product1 = create(:product, user: seller)
      product2 = create(:product, user: seller)
      thumbnail1 = create(:thumbnail, product: product1)
      thumbnail2 = create(:thumbnail, product: product2)
      thumbnail1.mark_deleted!

      sales_data = presenter.creator_home_props[:sales]

      product1_data = sales_data.find { |s| s["id"] == product1.unique_permalink }
      product2_data = sales_data.find { |s| s["id"] == product2.unique_permalink }

      expect(product1_data["thumbnail"]).to be_nil
      expect(product2_data["thumbnail"]).to eq(thumbnail2.url)
    end

    it "excludes deleted products from the Best Selling section", :sidekiq_inline, :elasticsearch_wait_for_refresh do
      active_product = create(:product, user: seller, price_cents: 1000)
      deleted_product = create(:product, user: seller, price_cents: 2000)

      create_list(:purchase, 3, link: active_product, price_cents: active_product.price_cents, created_at: 1.day.ago)
      create_list(:purchase, 5, link: deleted_product, price_cents: deleted_product.price_cents, created_at: 2.days.ago)

      deleted_product.update!(deleted_at: Time.current)

      sales_data = presenter.creator_home_props[:sales]
      expect(sales_data.map { |p| p["id"] }).to contain_exactly(active_product.unique_permalink)
      expect(sales_data).not_to include(hash_including("id" => deleted_product.unique_permalink))
    end

    it "shows the 3 most sold products in past 30 days", :sidekiq_inline, :elasticsearch_wait_for_refresh do
      product1 = create(:product, user: seller)
      product2 = create(:product, user: seller)
      product3 = create(:product, user: seller, price_cents: 1500)
      product4 = create(:product, user: seller, price_cents: 99)

      create_list(:purchase, 10, link: product1, price_cents: product1.price_cents, created_at: 31.days.ago)
      create_list(:purchase, 5, link: product2, price_cents: product2.price_cents, created_at: 3.days.ago)
      create_list(:purchase, 2, link: product3, price_cents: product3.price_cents, created_at: 6.days.ago)
      create_list(:purchase, 7, link: product4, price_cents: product4.price_cents, created_at: 1.day.ago)

      expect(presenter.creator_home_props[:sales]).to match(
        [
          {
            "id" => product4.unique_permalink,
            "name" => "The Works of Edgar Gumstein",
            "thumbnail" => nil,
            "sales" => 7,
            "revenue" => 693.0,
            "visits" => 0,
            "today" => 0,
            "last_7" => 693,
            "last_30" => 693,
          },
          {
            "id" => product2.unique_permalink,
            "name" => "The Works of Edgar Gumstein",
            "thumbnail" => nil,
            "revenue" => 500.0,
            "sales" => 5,
            "visits" => 0,
            "today" => 0,
            "last_7" => 500,
            "last_30" => 500,
          },
          {
            "id" => product3.unique_permalink,
            "name" => "The Works of Edgar Gumstein",
            "thumbnail" => nil,
            "sales" => 2,
            "revenue" => 3000.0,
            "visits" => 0,
            "today" => 0,
            "last_7" => 3000,
            "last_30" => 3000,
          },
        ]
      )
    end

    it "includes sorted interlaced activity items", :sidekiq_inline, :elasticsearch_wait_for_refresh do
      seller.update!(created_at: 60.days.ago)
      sales = [
        create(:purchase, :from_seller, seller:, created_at: 8.hours.ago),
        create(:purchase, :from_seller, seller:, created_at: 6.hours.ago),
        create(:purchase, :from_seller, seller:, created_at: 4.hours.ago),
        create(:purchase, :from_seller, seller:, created_at: 2.hours.ago),
        create(:purchase, :from_seller, seller:, created_at: 1.hour.ago, is_bundle_product_purchase: true)
      ]
      followers = [
        create(:follower, user: seller, confirmed_at: 7.hours.ago),
        create(:follower, user: seller, confirmed_at: 5.hours.ago),
        create(:follower, user: seller, confirmed_at: 3.hour.ago),
      ]
      followers.last.update!(confirmed_at: nil, deleted_at: 1.hour.ago) # fourth event

      # Limiting to 3 allows us to check that we're truncating the results from the correct end:
      # Grab the last 3 sales + last 3 followers events, then get the last 3 of that.
      stub_const("#{described_class}::ACTIVITY_ITEMS_LIMIT", 3)

      expect(presenter.creator_home_props[:activity_items]).to match_array(
        [
          {
            "type" => "follower_removed",
            "timestamp" => "2022-05-16T23:00:00Z",
            "details" => {
              "email" => followers.last.email,
              "name" => nil
            }
          },
          {
            "type" => "new_sale",
            "timestamp" => "2022-05-16T22:00:00Z",
            "details" => {
              "price_cents" => sales.second_to_last.price_cents,
              "email" => sales.second_to_last.email,
              "full_name" => nil,
              "product_name" => sales.second_to_last.link.name,
              "product_unique_permalink" => sales.second_to_last.link.unique_permalink
            }
          },
          {
            "type" => "follower_added",
            "timestamp" => "2022-05-16T21:00:00Z",
            "details" => {
              "email" => followers.last.email,
              "name" => nil
            }
          }
        ]
      )
    end

    it "includes the verification error message from Stripe if there's an active Stripe account" do
      create(:merchant_account, user: seller)
      create(:user_compliance_info_request, user: seller, field_needed: UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID,
                                            verification_error: { code: "verification_document_fraudulent" })

      expect(seller.stripe_account).to be_present
      expect(presenter.creator_home_props[:stripe_verification_message]).to eq "The document might have been altered so it could not be verified."

      seller.stripe_account.delete_charge_processor_account!

      expect(seller.stripe_account).to be_nil
      expect(presenter.creator_home_props[:stripe_verification_message]).to be_nil
    end

    describe "balances" do
      before do
        allow_any_instance_of(UserBalanceStatsService).to receive(:fetch).and_return(
          {
            overview: {
              balance: 10_000,
              last_seven_days_sales_total: 5_000,
              last_28_days_sales_total: 15_000,
              sales_cents_total: 50_000
            },
          }
        )
      end

      it "includes formatted balance information" do
        balances = presenter.creator_home_props[:balances]

        expect(balances[:balance]).to eq "$100"
        expect(balances[:last_seven_days_sales_total]).to eq "$50"
        expect(balances[:last_28_days_sales_total]).to eq "$150"
        expect(balances[:total]).to eq "$500"
      end

      context "when seller should be shown currencies always" do
        before do
          allow(seller).to receive(:should_be_shown_currencies_always?).and_return(true)
        end

        it "includes currency in formatted balance information" do
          balances = presenter.creator_home_props[:balances]

          expect(balances[:balance]).to eq "$100 USD"
          expect(balances[:last_seven_days_sales_total]).to eq "$50 USD"
          expect(balances[:last_28_days_sales_total]).to eq "$150 USD"
          expect(balances[:total]).to eq "$500 USD"
        end
      end
    end

    describe "tax forms" do
      download_url = "https://s3.amazonaws.com/gumroad-specs/attachments/23b2d41ac63a40b5afa1a99bf38a0982/original/nyt.pdf"

      before do
        seller.update!(created_at: 2.years.ago)
        allow(seller).to receive(:eligible_for_1099?).and_return(true)
        allow(seller).to receive(:tax_form_1099_download_url).and_return(download_url)
      end

      it "includes tax forms since the seller's account was created" do
        expect(presenter.creator_home_props[:tax_forms]).to eq(
          {
            2022 => download_url,
            2021 => download_url,
            2020 => download_url,
          }
        )
      end

      it "only includes years where the seller is eligible for a 1099" do
        allow(seller).to receive(:eligible_for_1099?) do |year|
          [2022, 2021].include?(year)
        end

        expect(presenter.creator_home_props[:tax_forms]).to eq(
          {
            2022 => download_url,
            2021 => download_url,
          })
      end

      it "only includes years that have downloadable tax forms" do
        allow(seller).to receive(:tax_form_1099_download_url) do |year:|
          year == 2021 ? download_url : nil
        end

        expect(presenter.creator_home_props[:tax_forms]).to eq(
          {
            2021 => download_url,
          }
        )
      end
    end
  end
end
