module Shifty
  class Configuration
    attr_reader :default_policy

    def initialize
      @default_policy = :frozen
    end

    def default_policy=(policy_name)
      @default_policy = Policy.validate!(policy_name)
    end
  end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    def reset_configuration!
      @config = Configuration.new
    end

    def deprecation_warning(old_name, new_name)
      warn "[shifty] #{old_name} is deprecated and will be " \
           "removed in 1.0.0; use #{new_name} instead."
    end
  end
end
