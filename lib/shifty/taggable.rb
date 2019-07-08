module Shifty
  module Taggable
    def tags=(tag_arg)
      @tags = [tag_arg].flatten.compact
    end

    def criteria=(criteria_arg)
      @criteria = [criteria_arg].flatten.compact
    end

    def has_tag?(tag)
      @tags.include? tag
    end

    def criteria_passes?
      return true if @criteria.empty?

      @criteria.all? { |c| c.call(self) }
    end
  end
end
