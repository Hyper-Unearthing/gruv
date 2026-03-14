# frozen_string_literal: true

require_relative '../lib/communication_platform/discord/poller'
require_relative '../lib/communication_platform/discord/sender'
require_relative '../lib/writer_registry'

WriterRegistry.register_if_configured(
  'discord',
  CommunicationPlatform::Discord::Poller,
  config_key: 'discord'
)
