# frozen_string_literal: true

class PageViewsController < ApplicationController
  def show
    user = resolve_seller
    return head :not_found unless user

    page = user.pages.alive.published.find_by!(slug: params[:slug])

    render inertia: "Pages/Show", props: {
      page: {
        title: page.title,
        html_content: page.published_version&.html || page.html_content,
        slug: page.slug,
        seller: {
          name: user.display_name,
          username: user.username,
          avatar_url: user.avatar_url,
        },
      },
    }
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  private
    def resolve_seller
      return User.alive.find_by(username: params[:username]) if params[:username].present?

      Subdomain.find_seller_by_request(request) ||
        CustomDomain.find_by_host(request.host)&.user
    end
end
