# frozen_string_literal: true

require "spec_helper"

describe Product::StructuredData do
  let(:user) { create(:user, name: "John Doe") }
  let(:product) { create(:product, user:, name: "My Great Book") }

  describe "#structured_data" do
    context "when product is not an ebook" do
      before do
        product.update!(native_type: "digital")
      end

      it "returns an empty hash" do
        expect(product.structured_data).to eq({})
      end
    end

    context "when product is an ebook" do
      before do
        product.update!(native_type: Link::NATIVE_TYPE_EBOOK)
      end

      it "returns structured data with correct schema.org format" do
        data = product.structured_data

        expect(data["@context"]).to eq("https://schema.org")
        expect(data["@type"]).to eq("Book")
      end

      it "includes the product name" do
        data = product.structured_data

        expect(data["name"]).to eq("My Great Book")
      end

      it "includes the author information" do
        data = product.structured_data

        expect(data["author"]).to eq({
                                       "@type" => "Person",
                                       "name" => "John Doe"
                                     })
      end

      it "includes the product URL" do
        data = product.structured_data

        expect(data["url"]).to eq(product.long_url)
      end

      context "with description" do
        context "when custom_summary is present" do
          let(:custom_summary_text) { "This is a custom summary for the book" }

          before do
            product.save_custom_summary(custom_summary_text)
            product.update!(description: "This is the regular description")
          end

          it "uses custom_summary for description" do
            data = product.structured_data

            expect(data["description"]).to eq(custom_summary_text)
          end
        end

        context "when custom_summary is not present" do
          before do
            product.update!(description: "This is the regular description")
          end

          it "uses sanitized html_safe_description" do
            data = product.structured_data

            expect(data["description"]).to eq("This is the regular description")
          end
        end

        context "when description is blank" do
          before do
            product.update!(description: "")
          end

          it "returns nil for description" do
            data = product.structured_data

            expect(data["description"]).to be_nil
          end
        end

        context "when description exceeds 160 characters" do
          let(:long_description) { "a" * 200 }

          before do
            product.update!(description: long_description)
          end

          it "truncates description to 160 characters" do
            data = product.structured_data

            expect(data["description"].length).to be <= 160
            expect(data["description"]).to end_with("...")
          end
        end

        context "when description contains HTML tags" do
          before do
            product.update!(description: "<p>This is <strong>bold</strong> text</p>")
          end

          it "strips HTML tags from description" do
            data = product.structured_data

            expect(data["description"]).to eq("This is bold text")
          end
        end
      end

      context "with product files" do
        context "when there are no product files" do
          it "does not include workExample" do
            data = product.structured_data

            expect(data).not_to have_key("workExample")
          end
        end

        context "when there are product files that support ISBN" do
          context "with PDF file" do
            let!(:pdf_file) do
              create(:readable_document, link: product, filetype: "pdf")
            end

            it "includes workExample for the PDF" do
              data = product.structured_data

              expect(data["workExample"]).to be_an(Array)
              expect(data["workExample"].length).to eq(1)
              expect(data["workExample"].first).to include(
                "@type" => "Book",
                "bookFormat" => "EBook",
                "name" => "My Great Book (PDF)"
              )
            end

            context "when PDF has ISBN" do
              before do
                pdf_file.update!(isbn: "978-3-16-148410-0")
              end

              it "includes the ISBN in workExample" do
                data = product.structured_data

                expect(data["workExample"].first["isbn"]).to eq("978-3-16-148410-0")
              end
            end

            context "when PDF does not have ISBN" do
              before do
                pdf_file.update!(isbn: nil)
              end

              it "does not include ISBN in workExample" do
                data = product.structured_data

                expect(data["workExample"].first).not_to have_key("isbn")
              end
            end
          end

          context "with EPUB file" do
            let!(:epub_file) do
              create(:non_readable_document, link: product, filetype: "epub")
            end

            it "includes workExample for the EPUB" do
              data = product.structured_data

              expect(data["workExample"]).to be_an(Array)
              expect(data["workExample"].length).to eq(1)
              expect(data["workExample"].first).to include(
                "@type" => "Book",
                "bookFormat" => "EBook",
                "name" => "My Great Book (EPUB)"
              )
            end

            context "when EPUB has ISBN" do
              before do
                epub_file.update!(isbn: "978-0-306-40615-7")
              end

              it "includes the ISBN in workExample" do
                data = product.structured_data

                expect(data["workExample"].first["isbn"]).to eq("978-0-306-40615-7")
              end
            end
          end

          context "with MOBI file" do
            let!(:mobi_file) do
              create(:product_file, link: product, filetype: "mobi", url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/test.mobi")
            end

            it "includes workExample for the MOBI" do
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

          context "with multiple book files" do
            let!(:pdf_file) do
              create(:readable_document, link: product, filetype: "pdf", isbn: "978-3-16-148410-0")
            end
            let!(:epub_file) do
              create(:non_readable_document, link: product, filetype: "epub", isbn: "978-0-306-40615-7")
            end

            it "includes workExample for all book files" do
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

        context "when there are product files that do not support ISBN" do
          let!(:video_file) do
            create(:streamable_video, link: product)
          end

          it "does not include workExample" do
            data = product.structured_data

            expect(data).not_to have_key("workExample")
          end
        end

        context "with mixed file types" do
          let!(:pdf_file) do
            create(:readable_document, link: product, filetype: "pdf", isbn: "978-3-16-148410-0")
          end
          let!(:video_file) do
            create(:streamable_video, link: product)
          end

          it "only includes workExample for files that support ISBN" do
            data = product.structured_data

            expect(data["workExample"]).to be_an(Array)
            expect(data["workExample"].length).to eq(1)
            expect(data["workExample"].first["name"]).to include("PDF")
          end
        end

        context "with deleted product files" do
          let!(:pdf_file) do
            create(:readable_document, link: product, filetype: "pdf", isbn: "978-3-16-148410-0")
          end

          before do
            pdf_file.update!(deleted_at: Time.current)
          end

          it "does not include deleted files in workExample" do
            data = product.structured_data

            expect(data).not_to have_key("workExample")
          end
        end
      end
    end
  end
end
