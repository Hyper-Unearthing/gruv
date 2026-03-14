# frozen_string_literal: true

module CommunicationPlatform
  module Concerns
    module Poller
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def sender
          raise NotImplementedError, "#{self} must implement .sender"
        end
      end

      def start
        raise NotImplementedError, "#{self.class} must implement #start"
      end
    end
  end
end
