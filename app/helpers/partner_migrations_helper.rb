# frozen_string_literal: true

module PartnerMigrationsHelper
  BUTTON_CLASS = "inline-flex items-center justify-center gap-2 cursor-pointer border border-border rounded font-[inherit] no-underline transition-transform hover:-translate-1 hover:shadow active:translate-0 active:shadow-none disabled:opacity-30 disabled:hover:translate-0 disabled:hover:shadow-none px-4 py-3 text-base leading-snug"

  def partner_migration_button_class(primary: true)
    "#{BUTTON_CLASS} #{primary ? "bg-accent-with-text text-accent-foreground" : "bg-background"}"
  end

  def partner_migration_title(migration)
    "Move #{pluralize(migration.products.size, "product")} from #{migration.oauth_application.name} to Gumroad?"
  end
end
