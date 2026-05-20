# frozen_string_literal: true

class PageViewsController < ApplicationController
  def show
    user = if params[:username]
      User.find_by!(username: params[:username])
    else
      @custom_domain_seller
    end

    return head :not_found unless user

    page = user.pages.alive.published.find_by!(slug: params[:slug])

    render inertia: "Pages/Show", props: {
      page: {
        title: page.title,
        html_content: page.html_content,
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
end
