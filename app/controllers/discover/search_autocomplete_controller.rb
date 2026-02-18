# frozen_string_literal: true

class Discover::SearchAutocompleteController < ApplicationController
  def delete_search_suggestion
    DiscoverSearchSuggestion
      .by_user_or_browser(user: logged_in_user, browser_guid: cookies[:_gumroad_guid])
      .where(discover_searches: { query: params[:query] })
      .each(&:mark_deleted!)
    head :no_content
  end
end
