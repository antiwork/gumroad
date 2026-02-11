# frozen_string_literal: true

describe SendYearInReviewEmailJob do
  include PaymentsHelper, ProductPageViewHelpers

  describe ".perform" do
    context "when no payouts exist for the selected year" do
      let(:date) { Date.new(2021, 2, 22) }
      let!(:seller) do
        create(
          :user_with_compliance_info,
          :with_annual_report,
          year: (date.year - 1),
          created_at: (date - 1.year).to_time
        )
      end

      it "does send an email" do
        travel_to(date) do
          12.times { create_payment_with_purchase(seller, date - 1.year) }
        end

        expect do
          described_class.new.perform(seller.id, date.year)
        end.to change { ActionMailer::Base.deliveries.count }.by(0)
      end
    end

    context "when payouts exist for the selected year", :vcr, :elasticsearch_wait_for_refresh do
      let(:date) { Date.new(2022, 2, 22) }
      let!(:seller) do
        create(:user_with_compliance_info,
               :with_annual_report,
               name: "Seller",
               year: date.year,
               created_at: (date - 1.year).to_time
        )
      end

      before do
        buy_list_response = {
          "choices" => [
            {
              "message" => {
                "content" => "1. A nice desk lamp\n2. A hardcover notebook\n3. A cozy throw blanket\n4. A set of headphones\n5. A gourmet coffee kit"
              }
            }
          ]
        }
        allow(OpenAI::Client).to receive(:new).and_return(double("OpenAI::Client", chat: buy_list_response))
      end

      context "when seller made only affiliate sales" do
        before do
          create(:payment_completed, user: seller, amount_cents: 100_00, payout_period_end_date: date, created_at: date)
        end

        it "does not send an email" do
          expect do
            described_class.new.perform(seller.id, date.year)
          end.to_not change { ActionMailer::Base.deliveries.count }
        end
      end

      context "when seller sold only one product" do
        before do
          recreate_model_index(ProductPageView)
          allow_any_instance_of(User).to receive(:rank).and_return(2)

          travel_to(date) do
            product = create(:product, user: seller, name: "Product 1")
            create_payment_with_purchase(seller, date, product:, amount_cents: 1_000_00, ip_country: "United States")
            2.times { add_page_view(product, Time.current.iso8601, { country: "United States" }) }
          end

          allow_any_instance_of(Exports::Payouts::Annual).to receive(:perform) {
            {
              csv_file: Rack::Test::UploadedFile.new("#{Rails.root}/spec/support/fixtures/followers_import.csv"),
              total_amount: 1_000_00
            }
          }

          index_model_records(Purchase)
        end

        it "shows stats only for one product" do
          expect do
            described_class.new.perform(seller.id, date.year)
          end.to change { ActionMailer::Base.deliveries.count }.by(1)

          mail = ActionMailer::Base.deliveries.last
          expect(mail.to).to eq([seller.email])
          expect(mail.subject).to eq("Your 2022 in review")
          expect(mail.body.sanitized).to include("Views 2")
          expect(mail.body.sanitized).to include("Sales 1")
          expect(mail.body.sanitized).to include("Unique customers 1")
          expect(mail.body.sanitized).to include("Products sold 1")
          expect(mail.body.sanitized).to include("You ranked #2 among all creators")
          expect(mail.body.sanitized).to include("Your top product")
          expect(mail.body.sanitized).to match(/Product 1 \( \S+ \) -+ Views 2 Sales 1 Total 1K/)
          expect(mail.body.sanitized).to include("You earned a total of $1,000")
          expect(mail.body.sanitized).to include("You sold products in 1 country")
          expect(mail.body.sanitized).to_not include("Elsewhere")
          expect(mail.body.sanitized).to include("United States 2 1 $1K")
          expect(mail.body.sanitized).to include(seller.financial_annual_report_url_for(year: date.year))
        end

        it "renders the AI text list section" do
          expect do
            described_class.new.perform(seller.id, date.year)
          end.to change { ActionMailer::Base.deliveries.count }.by(1)

          mail = ActionMailer::Base.deliveries.last
          expect(mail.body.sanitized).to include("Hey, can you suggest some things I could buy with my Gumroad earnings")
          expect(mail.body.sanitized).to include("A nice desk lamp")
          expect(mail.body.sanitized).to include("A hardcover notebook")
          expect(mail.body.sanitized).to include("A cozy throw blanket")
          expect(mail.body.sanitized).to include("A set of headphones")
          expect(mail.body.sanitized).to include("A gourmet coffee kit")
        end
      end

      context "when seller is from US" do
        before do
          @product_permalinks = generate_data_for(seller, date, products_count: 10)
          @top_product_names = seller.products.where(unique_permalink: @product_permalinks.first(5)).pluck(:name)
        end

        context "when seller is eligible for 1099" do
          before { allow_any_instance_of(User).to receive(:eligible_for_1099?).and_return(true) }

          it "sends an email with 1099 eligibility confirmation" do
            expect do
              described_class.new.perform(seller.id, date.year)
            end.to change { ActionMailer::Base.deliveries.count }.by(1)

            mail = ActionMailer::Base.deliveries.last
            expect(mail.to).to eq([seller.email])
            expect(mail.subject).to eq("Your 2022 in review")
            expect(mail.body.sanitized).to include("Views 24")
            expect(mail.body.sanitized).to include("Sales 12")
            expect(mail.body.sanitized).to include("Unique customers 12")
            expect(mail.body.sanitized).to include("Products sold #{@product_permalinks.size}")
            @top_product_names.each do |product_name|
              expect(mail.body.sanitized).to match(/#{product_name} \( \S+ \)( =)? -+ Views \d+ Sales \d+ Total \d+/)
            end
            expect(mail.body.sanitized).to include("You earned a total of $1,200")
            expect(mail.body.sanitized).to include("You sold products in 1 country")
            expect(mail.body.sanitized).to_not include("United States")
            expect(mail.body.sanitized).to include("Elsewhere 24 12 $1.2K")
            expect(mail.body.sanitized).to include("Your 1099 form is available for download")
            expect(mail.body.sanitized).to include(seller.financial_annual_report_url_for(year: date.year))
          end

          context "when recipient is passed as param" do
            it "sends an email to recipient instead of seller" do
              expect do
                described_class.new.perform(seller.id, date.year, "gumbot@gumroad.com")
              end.to change { ActionMailer::Base.deliveries.count }.by(1)

              mail = ActionMailer::Base.deliveries.last
              expect(mail.to).to eq(["gumbot@gumroad.com"])
              expect(mail.subject).to eq("Your 2022 in review")
              expect(mail.body.sanitized).to include("Views 24")
              expect(mail.body.sanitized).to include("Sales 12")
              expect(mail.body.sanitized).to include("Unique customers 12")
              expect(mail.body.sanitized).to include("Products sold #{@product_permalinks.size}")
              @top_product_names.each do |product_name|
                expect(mail.body.sanitized).to match(/#{product_name} \( \S+ \)( =)? -+ Views \d+ Sales \d+ Total \d+/)
              end
              expect(mail.body.sanitized).to include("You earned a total of $1,200")
              expect(mail.body.sanitized).to include("You sold products in 1 country")
              expect(mail.body.sanitized).to_not include("United States")
              expect(mail.body.sanitized).to include("Elsewhere 24 12 $1.2K")
              expect(mail.body.sanitized).to include("Your 1099 form is available for download")
              expect(mail.body.sanitized).to include(seller.financial_annual_report_url_for(year: date.year))
            end
          end
        end

        context "when seller is not eligible for 1099" do
          it "sends an email with 1099 non eligibility confirmation" do
            expect do
              described_class.new.perform(seller.id, date.year)
            end.to change { ActionMailer::Base.deliveries.count }.by(1)

            mail = ActionMailer::Base.deliveries.last
            expect(mail.to).to eq([seller.email])
            expect(mail.subject).to eq("Your 2022 in review")
            expect(mail.body.sanitized).to include("Views 24")
            expect(mail.body.sanitized).to include("Sales 12")
            expect(mail.body.sanitized).to include("Unique customers 12")
            expect(mail.body.sanitized).to include("Products sold #{@product_permalinks.size}")
            @top_product_names.each do |product_name|
              expect(mail.body.sanitized).to match(/#{product_name} \( \S+ \)( =)? -+ Views \d+ Sales \d+ Total \d+/)
            end
            expect(mail.body.sanitized).to include("You earned a total of $1,200")
            expect(mail.body.sanitized).to include("You sold products in 1 country")
            expect(mail.body.sanitized).to_not include("United States")
            expect(mail.body.sanitized).to include("Elsewhere 24 12 $1.2K")
            expect(mail.body.sanitized).to include("You do not qualify for a 1099 this year.")
            expect(mail.body.sanitized).to include(seller.financial_annual_report_url_for(year: date.year))
          end
        end
      end

      context "when seller is not from US" do
        let(:seller) do
          create(
            :singaporean_user_with_compliance_info,
            :with_annual_report,
            name: "Seller",
            year: date.year,
            created_at: (date - 1.year).to_time
          )
        end

        before do
          @product_permalinks = generate_data_for(seller, date)
          top_products = seller.products.where(unique_permalink: @product_permalinks.first(5))
          @top_product_names = top_products.pluck(:name)

          # Mimic no product views
          recreate_model_index(ProductPageView)

          travel_to(date) do
            create_payment_with_purchase(seller, date, product: top_products.first, amount_cents: 100_00, ip_country: "Romania")
            add_page_view(top_products.first, Time.current.iso8601, { country: "Romania" })
          end

          index_model_records(Purchase)
        end

        it "sends an email without 1099 section" do
          expect do
            described_class.new.perform(seller.id, date.year)
          end.to change { ActionMailer::Base.deliveries.count }.by(1)

          mail = ActionMailer::Base.deliveries.last
          expect(mail.to).to eq([seller.email])
          expect(mail.subject).to eq("Your 2022 in review")
          expect(mail.body.sanitized).to include("Views 1")
          expect(mail.body.sanitized).to include("Sales 13")
          expect(mail.body.sanitized).to include("Unique customers 13")
          expect(mail.body.sanitized).to include("Products sold #{@product_permalinks.size}")
          @top_product_names.each do |product_name|
            expect(mail.body.sanitized).to match(/#{product_name} \( \S+ \)( =)? -+ Views \d+ Sales \d+ Total \d+/)
          end
          expect(mail.body.sanitized).to include("You earned a total of $1,300")
          expect(mail.body.sanitized).to include("You sold products in 2 countries")
          expect(mail.body.sanitized).to_not include("United States")
          expect(mail.body.sanitized).to include("Romania 1 1 $100")
          expect(mail.body.sanitized).to include("Elsewhere 0 12 $1.2K")
          expect(mail.body.sanitized).to include(seller.financial_annual_report_url_for(year: date.year))
          expect(mail.body.sanitized).to_not include("You do not qualify for a 1099 this year.")
          expect(mail.body.sanitized).to_not include("Your 1099 form is available for download")
        end
      end
    end
  end

  private
    def generate_data_for(seller, date, products_count: 8)
      recreate_model_index(ProductPageView)

      products = build_list(:product, products_count, user: seller) do |product, i|
        product.name = "Product #{i + 1}"
        product.save!
      end
      product_sales_for_current_year = products.to_h { |product| [product.unique_permalink, 0] }

      travel_to(date - 1.year) do
        12.times do
          payment_data = create_payment_with_purchase(seller, date - 1.year, product: products.sample, amount_cents: 100_00)
          add_page_view(payment_data[:purchase].link)
        end
      end

      travel_to(date) do
        12.times do
          product = products.sample
          payment_data = create_payment_with_purchase(seller, date, product:, amount_cents: 100_00)
          2.times { add_page_view(product) }
          product_sales_for_current_year[product.unique_permalink] += payment_data[:payment].amount_cents
        end

        allow_any_instance_of(Exports::Payouts::Annual).to receive(:perform) {
          {
            csv_file: Rack::Test::UploadedFile.new("#{Rails.root}/spec/support/fixtures/followers_import.csv"),
            total_amount: 1_000_00
          }
        }
      end

      index_model_records(Purchase)

      product_sales_for_current_year.filter { |_, total| total.nonzero? }
                                    .sort_by { |key, total_sales| [-total_sales, key] }
                                    .map(&:first)
    end
end
