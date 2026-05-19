# frozen_string_literal: true

module ApplicationHelper
  def vite_entrypoint_stylesheet_tag(name, **options)
    entry = ViteRuby.instance.manifest.resolve_entries(name, type: :typescript)
    options[:extname] = false if Rails::VERSION::MAJOR >= 7
    stylesheets = entry.fetch(:stylesheets, [])
    return vite_stylesheet_tag("entrypoints/#{name}.scss", **options) if stylesheets.empty?
    stylesheet_link_tag(*stylesheets, **options)
  end

  def s3_bucket_url
    "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}"
  end

  def default_footer_content
    safe_join(
      [
        "Powered by",
        tag.span("Gumroad", class: "inline-block aspect-115/22 h-[1lh] shrink-0 bg-current mask-(--logo) mask-contain mask-center mask-no-repeat")
      ],
      " "
    )
  end

  def current_user_props(current_user, impersonated_user)
    {
      name: current_user.display_name,
      avatar_url: current_user.avatar_url,
      impersonated_user: impersonated_user.present? ? {
        name: impersonated_user.display_name,
        avatar_url: impersonated_user.avatar_url
      } : nil
    }
  end

  def number_to_si(number)
    number_to_human(
      number,
      units: { unit: "", thousand: "K", million: "M", billion: "B", trillion: "T" },
      precision: 1,
      significant: false,
      round_mode: :truncate,
      format: "%n%u"
    )
  end
end
