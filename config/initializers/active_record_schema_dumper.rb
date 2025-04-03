# frozen_string_literal: true

class ActiveRecord::SchemaDumper
  alias_method :original_index_parts, :index_parts
  def index_parts(index)
    parts = original_index_parts(index)
    parts[0].delete!("\\")
    parts
  end
end
