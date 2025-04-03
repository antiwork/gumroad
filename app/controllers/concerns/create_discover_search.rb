# frozen_string_literal: true

module CreateDiscoverSearch
  def create_discover_search!(extras = {})
    return if is_bot?
    return unless Feature.active?(:store_discover_searches, OpenStruct.new(flipper_id: cookies[:_gumroad_guid]))

    DiscoverSearch.transaction do
      search = DiscoverSearch.create!({
        user: logged_in_user,
        ip_address: request.remote_ip,
        browser_guid: cookies[:_gumroad_guid],
      }.merge(extras))

      search.create_discover_search_suggestion! if search.query.present? && !search.autocomplete
    end
  end
end
