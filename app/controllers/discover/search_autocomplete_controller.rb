# frozen_string_literal: true

class Discover::SearchAutocompleteController < ApplicationController
  include CreateDiscoverSearch

  def search
    create_discover_search!(query: params[:query], autocomplete: true) if params[:query].present?
    render json: Discover::AutocompletePresenter.new(
      query: params[:query],
      user: logged_in_user,
      browser_guid: cookies[:_gumroad_guid]
    ).props
  end

  def delete_search_suggestion
    DiscoverSearchSuggestion
      .by_user_or_browser(user: logged_in_user, browser_guid: cookies[:_gumroad_guid])
      .where(discover_searches: { query: params[:query] })
      .each(&:mark_deleted!)
    head :no_content
  end
end
