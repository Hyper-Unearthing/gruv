# frozen_string_literal: true

require 'fileutils'
require 'securerandom'
require 'base64'
require 'stringio'
require_relative 'instance_file_scope'

module MediaStorage
  IMAGE_EXTENSIONS = ['.jpg', '.jpeg', '.png', '.gif', '.webp'].freeze

  def self.save_bytes(dir_name:, bytes:, identifier:, index:, fallback_prefix:, filename_hint: nil, fallback_ext: nil, content_type: nil)
    destination_dir = File.join(InstanceFileScope.instance_dir, dir_name)
    FileUtils.mkdir_p(destination_dir)

    ext = extension_for(filename_hint: filename_hint, content_type: content_type, fallback_ext: fallback_ext)
    safe_name = safe_basename(filename_hint, fallback: "#{fallback_prefix}_#{index}")

    timestamp = Time.now.utc.strftime('%Y%m%d_%H%M%S')
    filename = "#{timestamp}_#{index}_#{fallback_prefix}_#{identifier}_#{safe_name}_#{SecureRandom.hex(4)}#{ext}"
    path = File.join(destination_dir, filename)

    File.binwrite(path, bytes)
    path
  end

  def self.extension_for(filename_hint:, content_type:, fallback_ext: nil)
    ext = File.extname(filename_hint.to_s)
    ext = extension_from_content_type(content_type) if ext.empty?
    ext = fallback_ext if ext.empty? && fallback_ext
    ext
  end

  CONTENT_TYPE_BY_EXT = {
    '.png'  => 'image/png',
    '.jpg'  => 'image/jpeg',
    '.jpeg' => 'image/jpeg',
    '.gif'  => 'image/gif',
    '.webp' => 'image/webp',
    '.mp3'  => 'audio/mpeg',
    '.ogg'  => 'audio/ogg',
    '.mp4'  => 'video/mp4'
  }.freeze

  def self.extension_from_content_type(content_type)
    return '' unless content_type

    CONTENT_TYPE_BY_EXT.find { |_ext, ct| content_type.start_with?(ct) }&.first || ''
  end

  def self.content_type_for(filename)
    ext = File.extname(filename.to_s).downcase
    CONTENT_TYPE_BY_EXT[ext] || 'application/octet-stream'
  end

  def self.image_file?(content_type:, filename:)
    return true if content_type && content_type.start_with?('image/')

    IMAGE_EXTENSIONS.include?(File.extname(filename.to_s).downcase)
  end

  def self.safe_basename(filename_hint, fallback:)
    base = File.basename(filename_hint.to_s, '.*')
    base = fallback if base.empty?
    base.gsub(/[^a-zA-Z0-9._-]/, '_')
  end

  def self.resolve_media_input(media)
    if File.exist?(media)
      [StringIO.new(File.binread(media)), File.basename(media)]
    elsif media.start_with?('base64:')
      [StringIO.new(Base64.decode64(media.sub('base64:', ''))), nil]
    else
      raise ArgumentError, "media must be a local file path or base64:..."
    end
  end
end
