# frozen_string_literal: true

class Api::V2::BaseController < ApplicationController
  after_action :log_method_use

  private
    def fetch_product
      products = current_resource_owner.links
      @product = products.find_by_external_id(params[:link_id]) || products.find_by(unique_permalink: params[:link_id]) || error_with_object(:product, nil)
    end

    def render_response(success, result = {})
      result = result.as_json(api_scopes: doorkeeper_token.scopes)
      render json: { success: }.merge(result)
    end

    def current_resource_owner
      User.find(doorkeeper_token.resource_owner_id) if doorkeeper_token.present?
    end

    def success_with_object(object_type, object, additional_info = {})
      if object.nil?
        render_response(true, message: "The #{object_type} was deleted successfully.")
      else
        render_response(true, { object_type => object }.merge(additional_info))
      end
    end

    # TODO we should return status code 404 Not Found when object is not found and 422 Unprocessable Entity when it's unable to be modified.
    # There's a (small) chance this will break existing integrations, but should be improved in the next version of the API.
    # https://gumroad.slack.com/archives/C5Z7LG6Q1/p1602496811465200
    def error_with_object(object_name, object)
      message = if object.present?
        if object.respond_to?(:errors) && object.errors.present?
          object.errors.full_messages.to_sentence
        else
          "The #{object_name} was unable to be modified."
        end
      else
        "The #{object_name} was not found."
      end
      render_response(false, message:)
    end

    def error_with_creating_object(object_name, object = nil)
      message = if object.present?
        object.errors.full_messages.to_sentence
      else
        "The #{object_name} was unable to be created."
      end
      render_response(false, message:)
    end

    def error_400(error_output = "Invalid request.")
      output = { status: 400, error: error_output }
      render status: :bad_request, json: output
    end

    def log_method_use
      return unless current_resource_owner.present?
      return unless doorkeeper_token.present?

      Rails.logger.info("api v2 user:#{current_resource_owner.id} token:#{doorkeeper_token.id} in #{params[:controller]}##{params[:action]}")
    end

    def next_page_url(page_key)
      uri = Addressable::URI.parse(request.original_url)
      uri.query_values = (uri.query_values || {}).except("access_token", "page", "page_key").merge(page_key:)
      "#{uri.path}?#{uri.query}"
    end

    def encode_page_key(record)
      record.created_at.to_fs(:usec) + "-" + ObfuscateIds.encrypt_numeric(record.id).to_s
    end

    def decode_page_key(string)
      date_string, obfuscated_id = string.split("-")
      last_record_obfuscated_id = obfuscated_id.to_i
      raise ArgumentError if last_record_obfuscated_id == 0
      [Time.zone.parse(date_string.gsub(/(\d{6})\z/, '.\1')), ObfuscateIds.decrypt_numeric(last_record_obfuscated_id).to_i]
    end

    def pagination_info(record)
      next_page_key = encode_page_key(record)
      {
        next_page_key:,
        next_page_url: next_page_url(next_page_key)
      }
    end
end
