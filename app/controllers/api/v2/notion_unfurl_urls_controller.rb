# frozen_string_literal: true

class Api::V2::NotionUnfurlUrlsController < Api::V2::BaseController
  before_action(only: [:create]) { doorkeeper_authorize! :unfurl }
  before_action :parse_uri, only: [:create]
  before_action :fetch_product, only: [:create]
  skip_before_action :verify_authenticity_token, only: [:create, :destroy]

  def create
    render_link_preview_payload
  end

  def destroy
    head :ok
  end

  private
    def parse_uri
      return render_no_uri_error if params[:uri].blank?

      @parsed_uri = Addressable::URI.parse(params[:uri])
      return render_invalid_uri_error if @parsed_uri.host.blank?

      @parsed_uri.query = nil
    end

    def fetch_product
      seller = Subdomain.find_seller_by_hostname(@parsed_uri.host)
      return render_invalid_uri_error if seller.blank? || !@parsed_uri.path.start_with?("/l/")

      permalink = @parsed_uri.path.match(/\/l\/([\w-]+)/)&.captures&.first
      return render_invalid_uri_error if permalink.blank?

      @product = Link.fetch_leniently(permalink, user: seller)
      render_invalid_uri_error if @product.blank?
    end

    def render_link_preview_payload
      total_ratings = @product.rating_counts.values.sum
      attributes = [
        {
          "id": "title",
          "name": "Product name",
          "inline": {
            "title": {
              "value": @product.name,
              "section": "title"
            }
          }
        },
        {
          "id": "creator_name",
          "name": "Creator name",
          "type": "inline",
          "inline": {
            "plain_text": {
              "value": @product.user.display_name,
              "section": "secondary",
            }
          }
        },
        {
          "id": "rating",
          "name": "Rating",
          "type": "inline",
          "inline": {
            "plain_text": {
              "value": %(★ #{@product.average_rating}#{total_ratings.zero? ? "" : " (#{pluralize(total_ratings, "rating")})"}),
              "section": "secondary",
            }
          }
        },
        {
          "id": "price",
          "name": "Price",
          "type": "inline",
          "inline": {
            "enum": {
              "value": @product.price_formatted_including_rental_verbose,
              "color": {
                "r": 255,
                "g": 144,
                "b": 232
              },
              "section": "primary",
            }
          }
        },
        {
          "id": "site",
          "name": "Site",
          "type": "inline",
          "inline": {
            "plain_text": {
              "value": @parsed_uri.to_s,
              "section": "secondary"
            }
          }
        }
      ]

      if @product.plaintext_description.present?
        attributes << {
          "id": "description",
          "name": "Description",
          "type": "inline",
          "inline": {
            "plain_text": {
              "value": @product.plaintext_description.truncate(255),
              "section": "body"
            }
          }
        }
      end

      main_cover_image_url = @product.main_preview&.url
      if main_cover_image_url.present?
        attributes << {
          "id": "media",
          "name": "Embed",
          "embed": {
            "src_url": main_cover_image_url,
            "image": { "section": "embed" }
          }
        }
      end

      render json: {
        uri: params[:uri],
        operations: [{ path: ["attributes"], set: attributes }]
      }
    end

    def render_no_uri_error
      render json: {
        error: {
          status: 404,
          message: "Product not found"
        }
      }, status: :not_found
    end

    def render_invalid_uri_error
      render json: {
        uri: params[:uri],
        operations: [{
          path: ["error"],
          set: { "status": 404, "message": "Product not found" }
        }]
      }, status: :not_found
    end

    def doorkeeper_unauthorized_render_options(**)
      {
        json: {
          error: {
            status: 401,
            message: "Request need to be authorized. Required parameter for authorizing request is missing or invalid."
          }
        }
      }
    end
end
