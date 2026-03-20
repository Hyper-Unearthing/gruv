# frozen_string_literal: true

require_relative '../lib/communication_platform/telegram/poller'
require_relative '../lib/communication_platform/telegram/sender'
require_relative '../lib/writer_registry'

WriterRegistry.register_if_configured(
  'telegram',
  CommunicationPlatform::Telegram::Poller,
  config_key: 'telegram'
)
