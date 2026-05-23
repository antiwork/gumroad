# frozen_string_literal: true

require "test_helper"

class ProductStructuredDataTest < ActiveSupport::TestCase
  self.described_class = Product::StructuredData



  context_ Product::StructuredData do
    let(:user) { create(:user, name: "John Doe") }
    let(:product) { create(:product, user:, name: "My Great Book") }

  context_ "#structured_data" do
  context_ "when product is not an ebook" do
        before do
          product.update!(native_type: "digital")
        end

  context_ "without reviews" do
  test "returns an empty hash" do
            expect(product.structured_data).to eq({})
          end
        end

  context_ "with reviews disabled" do
          before do
            product.display_product_reviews = false
            product.save!
            create(:product_review_stat, link: product, reviews_count: 5, average_rating: 4.5,
                                         ratings_of_five_count: 4, ratings_of_four_count: 1)
          end

  test "returns an empty hash" do
            expect(product.structured_data).to eq({})
          end
        end

  context_ "with reviews enabled and reviews present" do
          before do
            product.display_product_reviews = true
            product.save!
            create(:product_review_stat, link: product, reviews_count: 12, average_rating: 4.8,
                                         ratings_of_five_count: 10, ratings_of_four_count: 2)
          end

  test "returns a Product schema" do
            data = product.structured_data

            expect(data["@context"]).to eq("https://schema.org")
            expect(data["@type"]).to eq("Product")
          end

  test "includes the product name" do
            expect(product.structured_data["name"]).to eq("My Great Book")
          end

  test "includes the product URL" do
            expect(product.structured_data["url"]).to eq(product.long_url)
          end

  test "includes aggregateRating" do
            rating = product.structured_data["aggregateRating"]

            expect(rating["@type"]).to eq("AggregateRating")
            expect(rating["ratingValue"]).to eq(4.8)
            expect(rating["reviewCount"]).to eq(12)
            expect(rating["bestRating"]).to eq(5)
            expect(rating["worstRating"]).to eq(1)
          end

  test "includes an offer with price" do
            offer = product.structured_data["offers"]

            expect(offer["@type"]).to eq("Offer")
            expect(offer["priceCurrency"]).to eq("USD")
            expect(offer["price"]).to eq(product.price_cents / 100.0)
            expect(offer["availability"]).to eq(Product::StructuredData::AVAILABILITY_IN_STOCK)
            expect(offer["url"]).to eq(product.long_url)
          end

  context_ "when the product is pay-what-you-want with no minimum" do
            before do
              product.price_cents = 0
              product.customizable_price = true
              product.save!
            end

  test "includes price as 0 in the offer" do
              offer = product.structured_data["offers"]

              expect(offer["price"]).to eq(0.0)
            end
          end

  context_ "when the product is buy-and-rent" do
            before do
              product.update!(price_cents: 500, purchase_type: :buy_and_rent, rental_price_cents: 300)
            end

  test "uses the lower rental price in the offer" do
              offer = product.structured_data["offers"]

              expect(offer["price"]).to eq(3.0)
            end
          end

  context_ "when the product is a subscription with multiple recurrences" do
            let(:product) { create(:subscription_product, user:, name: "My Great Book", price_cents: 500) }

            before do
              create(:price, link: product, recurrence: BasePrice::Recurrence::YEARLY, price_cents: 4000)
              product.reload
            end

  test "uses the lowest recurrence price in the offer" do
              offer = product.structured_data["offers"]

              expect(offer["price"]).to eq(5.0)
            end
          end

  context_ "when the product has a sales limit with remaining stock" do
            before do
              product.update!(max_purchase_count: 10)
            end

  test "sets availability to LimitedAvailability" do
              expect(product.structured_data["offers"]["availability"]).to eq(Product::StructuredData::AVAILABILITY_LIMITED)
            end
          end

  context_ "when the product is sold out" do
            before do
              product.update!(max_purchase_count: 10)
              allow(product).to receive(:remaining_for_sale_count).and_return(0)
            end

  test "sets availability to SoldOut" do
              expect(product.structured_data["offers"]["availability"]).to eq(Product::StructuredData::AVAILABILITY_SOLD_OUT)
            end
          end
        end
      end

  context_ "when product is an ebook" do
        before do
          product.update!(native_type: Link::NATIVE_TYPE_EBOOK)
        end

  test "returns structured data with correct schema.org format" do
          data = product.structured_data

          expect(data["@context"]).to eq("https://schema.org")
          expect(data["@type"]).to eq("Book")
        end

  test "includes the product name" do
          data = product.structured_data

          expect(data["name"]).to eq("My Great Book")
        end

  test "includes an offer" do
          offer = product.structured_data["offers"]

          expect(offer["@type"]).to eq("Offer")
          expect(offer["priceCurrency"]).to eq("USD")
          expect(offer["price"]).to eq(product.price_cents / 100.0)
          expect(offer["availability"]).to eq(Product::StructuredData::AVAILABILITY_IN_STOCK)
          expect(offer["url"]).to eq(product.long_url)
        end

  test "includes the author information" do
          data = product.structured_data

          expect(data["author"]).to eq({
                                         "@type" => "Person",
                                         "name" => "John Doe"
                                       })
        end

  test "includes the product URL" do
          data = product.structured_data

          expect(data["url"]).to eq(product.long_url)
        end

  context_ "with description" do
  context_ "when custom_summary is present" do
            let(:custom_summary_text) { "This is a custom summary for the book" }

            before do
              product.save_custom_summary(custom_summary_text)
              product.update!(description: "This is the regular description")
            end

  test "uses custom_summary for description" do
              data = product.structured_data

              expect(data["description"]).to eq(custom_summary_text)
            end
          end

  context_ "when custom_summary is not present" do
            before do
              product.update!(description: "This is the regular description")
            end

  test "uses sanitized html_safe_description" do
              data = product.structured_data

              expect(data["description"]).to eq("This is the regular description")
            end
          end

  context_ "when description is blank" do
            before do
              product.update!(description: "")
            end

  test "returns nil for description" do
              data = product.structured_data

              expect(data["description"]).to be_nil
            end
          end

  context_ "when description exceeds 160 characters" do
            let(:long_description) { "a" * 200 }

            before do
              product.update!(description: long_description)
            end

  test "truncates description to 160 characters" do
              data = product.structured_data

              expect(data["description"].length).to be <= 160
              expect(data["description"]).to end_with("...")
            end
          end

  context_ "when description contains HTML tags" do
            before do
              product.update!(description: "<p>This is <strong>bold</strong> text</p>")
            end

  test "strips HTML tags from description" do
              data = product.structured_data

              expect(data["description"]).to eq("This is bold text")
            end
          end
        end

  context_ "with reviews enabled and reviews present" do
          before do
            product.display_product_reviews = true
            product.save!
            create(:product_review_stat, link: product, reviews_count: 8, average_rating: 4.3,
                                         ratings_of_five_count: 5, ratings_of_four_count: 3)
          end

  test "includes aggregateRating in the Book schema" do
            rating = product.structured_data["aggregateRating"]

            expect(rating["@type"]).to eq("AggregateRating")
            expect(rating["ratingValue"]).to eq(4.3)
            expect(rating["reviewCount"]).to eq(8)
          end

  test "keeps the Book type" do
            expect(product.structured_data["@type"]).to eq("Book")
          end
        end

  context_ "with reviews disabled" do
          before do
            product.display_product_reviews = false
            product.save!
            create(:product_review_stat, link: product, reviews_count: 8, average_rating: 4.3,
                                         ratings_of_five_count: 5, ratings_of_four_count: 3)
          end

  test "does not include aggregateRating" do
            expect(product.structured_data).not_to have_key("aggregateRating")
          end
        end

  context_ "with product files" do
  context_ "when there are no product files" do
  test "does not include workExample" do
              data = product.structured_data

              expect(data).not_to have_key("workExample")
            end
          end

  context_ "when there are product files that support ISBN" do
  context_ "with PDF file" do
              let!(:pdf_file) do
                create(:readable_document, link: product, filetype: "pdf")
              end

  test "includes workExample for the PDF" do
                data = product.structured_data

                expect(data["workExample"]).to be_an(Array)
                expect(data["workExample"].length).to eq(1)
                expect(data["workExample"].first).to include(
                  "@type" => "Book",
                  "bookFormat" => "EBook",
                  "name" => "My Great Book (PDF)"
                )
              end

  context_ "when PDF has ISBN" do
                before do
                  pdf_file.update!(isbn: "978-3-16-148410-0")
                end

  test "includes the ISBN in workExample" do
                  data = product.structured_data

                  expect(data["workExample"].first["isbn"]).to eq("978-3-16-148410-0")
                end
              end

  context_ "when PDF does not have ISBN" do
                before do
                  pdf_file.update!(isbn: nil)
                end

  test "does not include ISBN in workExample" do
                  data = product.structured_data

                  expect(data["workExample"].first).not_to have_key("isbn")
                end
              end
            end

  context_ "with EPUB file" do
              let!(:epub_file) do
                create(:non_readable_document, link: product, filetype: "epub")
              end

  test "includes workExample for the EPUB" do
                data = product.structured_data

                expect(data["workExample"]).to be_an(Array)
                expect(data["workExample"].length).to eq(1)
                expect(data["workExample"].first).to include(
                  "@type" => "Book",
                  "bookFormat" => "EBook",
                  "name" => "My Great Book (EPUB)"
                )
              end

  context_ "when EPUB has ISBN" do
                before do
                  epub_file.update!(isbn: "978-0-306-40615-7")
                end

  test "includes the ISBN in workExample" do
                  data = product.structured_data

                  expect(data["workExample"].first["isbn"]).to eq("978-0-306-40615-7")
                end
              end
            end

  context_ "with MOBI file" do
              let!(:mobi_file) do
                create(:product_file, link: product, filetype: "mobi", url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/test.mobi")
              end

  test "includes workExample for the MOBI" do
                data = product.structured_data

                expect(data["workExample"]).to be_an(Array)
                expect(data["workExample"].length).to eq(1)
                expect(data["workExample"].first).to include(
                  "@type" => "Book",
                  "bookFormat" => "EBook",
                  "name" => "My Great Book (MOBI)"
                )
              end
            end

  context_ "with multiple book files" do
              let!(:pdf_file) do
                create(:readable_document, link: product, filetype: "pdf", isbn: "978-3-16-148410-0")
              end
              let!(:epub_file) do
                create(:non_readable_document, link: product, filetype: "epub", isbn: "978-0-306-40615-7")
              end

  test "includes workExample for all book files" do
                data = product.structured_data

                expect(data["workExample"]).to be_an(Array)
                expect(data["workExample"].length).to eq(2)

                pdf_example = data["workExample"].find { |ex| ex["name"].include?("PDF") }
                epub_example = data["workExample"].find { |ex| ex["name"].include?("EPUB") }

                expect(pdf_example["isbn"]).to eq("978-3-16-148410-0")
                expect(epub_example["isbn"]).to eq("978-0-306-40615-7")
              end
            end
          end

  context_ "when there are product files that do not support ISBN" do
            let!(:video_file) do
              create(:streamable_video, link: product)
            end

  test "does not include workExample" do
              data = product.structured_data

              expect(data).not_to have_key("workExample")
            end
          end

  context_ "with mixed file types" do
            let!(:pdf_file) do
              create(:readable_document, link: product, filetype: "pdf", isbn: "978-3-16-148410-0")
            end
            let!(:video_file) do
              create(:streamable_video, link: product)
            end

  test "only includes workExample for files that support ISBN" do
              data = product.structured_data

              expect(data["workExample"]).to be_an(Array)
              expect(data["workExample"].length).to eq(1)
              expect(data["workExample"].first["name"]).to include("PDF")
            end
          end

  context_ "with deleted product files" do
            let!(:pdf_file) do
              create(:readable_document, link: product, filetype: "pdf", isbn: "978-3-16-148410-0")
            end

            before do
              pdf_file.update!(deleted_at: Time.current)
            end

  test "does not include deleted files in workExample" do
              data = product.structured_data

              expect(data).not_to have_key("workExample")
            end
          end
        end
      end
    end
  end
end
