module Shifty
  class Configuration
    attr_accessor :default_policy

    def initialize
      @default_policy = :frozen
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
  end
end
