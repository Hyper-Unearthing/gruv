# frozen_string_literal: true

module RuntimeConfig
  class << self
    attr_accessor :provider_name

    def set(provider_name:)
      @provider_name = provider_name
    end
  end
end
