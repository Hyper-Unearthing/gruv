#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'uri'
require 'fileutils'

CONFIG_PATH = File.expand_path('instance/config.json', __dir__)

def tty
  @tty ||= File.open('/dev/tty', 'r+')
end

def prompt(label, default: nil, required: false)
  loop do
    if default
      tty.print("#{label} [#{default}]: ")
    else
      tty.print("#{label}: ")
    end

    value = tty.gets&.strip
    value = default if value == '' && default

    if required && (value.nil? || value == '')
      tty.puts('This value is required.')
      next
    end

    return value
  end
end

def load_config
  return {} unless File.exist?(CONFIG_PATH)

  JSON.parse(File.read(CONFIG_PATH))
rescue JSON::ParserError
  {}
end

def parse_return_url(url)
  uri = URI(url)
  params = URI.decode_www_form(uri.query || '').to_h

  {
    'discord_install_return_url' => url,
    'discord_install_code' => params['code'],
    'discord_install_guild_id' => params['guild_id'],
    'discord_install_permissions' => params['permissions'],
    'discord_install_scope' => params['scope'],
    'discord_install_error' => params['error'],
    'discord_install_error_description' => params['error_description']
  }
end

def build_install_url(client_id:, scopes:, permissions:, redirect_uri:)
  query = {
    'client_id' => client_id,
    'scope' => scopes,
    'permissions' => permissions
  }

  if redirect_uri && redirect_uri != ''
    query['redirect_uri'] = redirect_uri
    query['response_type'] = 'code'
  end

  "https://discord.com/oauth2/authorize?#{URI.encode_www_form(query)}"
end

begin
  config = load_config

  puts '=== Chat integrations setup ==='
  puts "Config file: #{CONFIG_PATH}"
  puts

  telegram_bot_token = prompt('Telegram bot token (optional)')

  discord_bot_token = prompt('Discord bot token', required: true)
  discord_client_id = prompt('Discord application client id', required: true)
  discord_client_secret = prompt('Discord client secret (optional)')
  discord_redirect_uri = prompt('Discord redirect URI (optional, needed to capture code)')
  discord_oauth_scopes = prompt('Discord scopes', default: 'bot applications.commands')
  discord_permissions = prompt('Discord permissions integer', default: '274877991936')

  install_url = build_install_url(
    client_id: discord_client_id,
    scopes: discord_oauth_scopes,
    permissions: discord_permissions,
    redirect_uri: discord_redirect_uri
  )

  puts
  puts 'Open this Discord installation URL:'
  puts install_url
  puts

  return_url = prompt('Paste resulting browser URL after installation (optional)')

  updates = {
    'discord_bot_token' => discord_bot_token,
    'discord_client_id' => discord_client_id,
    'discord_oauth_scopes' => discord_oauth_scopes,
    'discord_permissions' => discord_permissions,
    'discord_install_url' => install_url
  }

  updates['telegram_bot_token'] = telegram_bot_token if telegram_bot_token && telegram_bot_token != ''
  updates['discord_client_secret'] = discord_client_secret if discord_client_secret && discord_client_secret != ''
  updates['discord_redirect_uri'] = discord_redirect_uri if discord_redirect_uri && discord_redirect_uri != ''

  if return_url && return_url != ''
    updates.merge!(parse_return_url(return_url))
  end

  config.merge!(updates)
  FileUtils.mkdir_p(File.dirname(CONFIG_PATH))
  File.write(CONFIG_PATH, JSON.pretty_generate(config) + "\n")

  puts
  puts "Saved setup to #{CONFIG_PATH}"
rescue URI::InvalidURIError => e
  warn "Invalid URL: #{e.message}"
  exit 1
ensure
  tty.close if defined?(@tty) && @tty && !@tty.closed?
end
