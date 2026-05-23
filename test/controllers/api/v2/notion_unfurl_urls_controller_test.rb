# frozen_string_literal: true

require "test_helper"

class ApiV2NotionUnfurlUrlsControllerTest < ActionController::TestCase
  self.described_class = Api::V2::NotionUnfurlUrlsController
  tests Api::V2::NotionUnfurlUrlsController



  context_ Api::V2::NotionUnfurlUrlsController do
    let!(:seller) { create(:user, username: "john") }
    let!(:product) { create(:product, name: "An ultimate guide to become a programmer!", description: "<p>Lorem ipsum</p>", user: seller) }
    let!(:access_token) { create("doorkeeper/access_token", application: create(:oauth_application, owner: create(:user)), resource_owner_id: create(:user).id, scopes: "unfurl") }

  context_ "POST create" do
  context_ "when the request is not authorized" do
  test "returns error" do
          post :create

          expect(response).to have_http_status(:unauthorized)
          expect(response.parsed_body).to eq("error" => { "status" => 401, "message" => "Request need to be authorized. Required parameter for authorizing request is missing or invalid." })
        end
      end

  context_ "when the request is authorized" do
        before do
          request.headers["Authorization"] = "Bearer #{access_token.token}"
        end

  context_ "when the 'uri' parameter is not specified" do
  test "returns error" do
            post :create

            expect(response).to have_http_status(:not_found)
            expect(response.parsed_body).to eq("error" => { "status" => 404, "message" => "Product not found" })
          end
        end

  context_ "when the specified 'uri' parameter is not a valid URI" do
  test "returns error" do
            post :create, params: { uri: "example.com" }

            expect(response).to have_http_status(:not_found)
            expect(response.parsed_body).to eq({
                                                 "uri" => "example.com",
                                                 "operations" => [{
                                                   "path" => ["error"],
                                                   "set" => { "status" => 404, "message" => "Product not found" }
                                                 }]
                                               })
          end
        end

  context_ "when corresponding seller is not found for the specified 'uri'" do
          let(:uri) { "#{PROTOCOL}://someone.#{ROOT_DOMAIN}" }

  test "returns error" do
            post :create, params: { uri: }

            expect(response).to have_http_status(:not_found)
            expect(response.parsed_body).to eq({
                                                 "uri" => uri,
                                                 "operations" => [{
                                                   "path" => ["error"],
                                                   "set" => { "status" => 404, "message" => "Product not found" }
                                                 }]
                                               })
          end
        end

  context_ "when corresponding seller exists but the specified 'uri' is not a valid product URL" do
          let(:uri) { "#{PROTOCOL}://john.#{ROOT_DOMAIN}/products" }

  test "returns error" do
            post :create, params: { uri: }

            expect(response).to have_http_status(:not_found)
            expect(response.parsed_body).to eq({
                                                 "uri" => uri,
                                                 "operations" => [{
                                                   "path" => ["error"],
                                                   "set" => { "status" => 404, "message" => "Product not found" }
                                                 }]
                                               })
          end
        end

  context_ "when 'uri' does not contain a product permalink" do
          let(:uri) { "#{PROTOCOL}://john.#{ROOT_DOMAIN}/l/" }

  test "returns error" do
            post :create, params: { uri: }

            expect(response).to have_http_status(:not_found)
            expect(response.parsed_body).to eq({
                                                 "uri" => uri,
                                                 "operations" => [{
                                                   "path" => ["error"],
                                                   "set" => { "status" => 404, "message" => "Product not found" }
                                                 }]
                                               })
          end
        end

  context_ "when no product is found for the specified 'uri'" do
          let(:uri) { "#{PROTOCOL}://john.#{ROOT_DOMAIN}/l/hello" }

  test "returns error" do
            post :create, params: { uri: }

            expect(response).to have_http_status(:not_found)
            expect(response.parsed_body).to eq({
                                                 "uri" => uri,
                                                 "operations" => [{
                                                   "path" => ["error"],
                                                   "set" => { "status" => 404, "message" => "Product not found" }
                                                 }]
                                               })
          end
        end

  context_ "when 'uri' is a valid product URL" do
          let(:uri) { "#{PROTOCOL}://john.#{ROOT_DOMAIN}/l/#{product.unique_permalink}" }

  test "returns necessary payload for rendering its preview" do
            post :create, params: { uri: "#{uri}?hello=test" }

            expect(response).to have_http_status(:ok)
            expect(response.parsed_body).to eq({
                                                 "uri" => "#{uri}?hello=test",
                                                 "operations" => [{
                                                   "path" => ["attributes"],
                                                   "set" => [
                                                     {
                                                       "id" => "title",
                                                       "name" => "Product name",
                                                       "inline" => {
                                                         "title" => {
                                                           "value" => "An ultimate guide to become a programmer!",
                                                           "section" => "title"
                                                         }
                                                       }
                                                     },
                                                     {
                                                       "id" => "creator_name",
                                                       "name" => "Creator name",
                                                       "type" => "inline",
                                                       "inline" => {
                                                         "plain_text" => {
                                                           "value" => "john",
                                                           "section" => "secondary",
                                                         }
                                                       }
                                                     },
                                                     {
                                                       "id" => "rating",
                                                       "name" => "Rating",
                                                       "type" => "inline",
                                                       "inline" => {
                                                         "plain_text" => {
                                                           "value" => "★ 0.0",
                                                           "section" => "secondary",
                                                         }
                                                       }
                                                     },
                                                     {
                                                       "id" => "price",
                                                       "name" => "Price",
                                                       "type" => "inline",
                                                       "inline" => {
                                                         "enum" => {
                                                           "value" => "$1",
                                                           "color" => {
                                                             "r" => 255,
                                                             "g" => 144,
                                                             "b" => 232
                                                           },
                                                           "section" => "primary",
                                                         }
                                                       }
                                                     },
                                                     {
                                                       "id" => "site",
                                                       "name" => "Site",
                                                       "type" => "inline",
                                                       "inline" => {
                                                         "plain_text" => {
                                                           "value" => uri,
                                                           "section" => "secondary"
                                                         }
                                                       }
                                                     },
                                                     {
                                                       "id" => "description",
                                                       "name" => "Description",
                                                       "type" => "inline",
                                                       "inline" => {
                                                         "plain_text" => {
                                                           "value" => "Lorem ipsum",
                                                           "section" => "body"
                                                         }
                                                       }
                                                     }
                                                   ]
                                                 }]
                                               })
          end

  context_ "when corresponding product has a cover image" do
            before do
              create(:asset_preview, link: product, unsplash_url: "https://images.unsplash.com/example.jpeg")
            end

  test "includes an embed attribute with the cover image URL" do
              post :create, params: { uri: }

              expect(response).to have_http_status(:ok)
              expect(response.parsed_body["operations"][0]["set"]).to include({
                                                                                "id" => "media",
                                                                                "name" => "Embed",
                                                                                "embed" => {
                                                                                  "src_url" => "https://images.unsplash.com/example.jpeg",
                                                                                  "image" => { "section" => "embed" }
                                                                                }
                                                                              })
            end
          end

  context_ "when corresponding product does not have a description" do
            before do
              product.update!(description: "")
            end

  test "does not include the description attribute" do
              post :create, params: { uri: }

              expect(response).to have_http_status(:ok)
              expect(response.parsed_body["operations"][0]["set"]).not_to include({
                                                                                    "id" => "description",
                                                                                    "name" => "Description",
                                                                                    "type" => "inline",
                                                                                    "inline" => {
                                                                                      "plain_text" => {
                                                                                        "value" => "Lorem ipsum",
                                                                                        "section" => "body"
                                                                                      }
                                                                                    }
                                                                                  })
            end
          end
        end
      end
    end

  context_ "DELETE destroy" do
      before do
        request.headers["Authorization"] = "Bearer #{access_token.token}"
      end

  test "returns with an OK response without doing anything else" do
        delete :destroy, params: { uri: "https://example.com" }

        expect(response).to have_http_status(:ok)
        expect(response.body).to eq("")
      end
    end
  end
end
