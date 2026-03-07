# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

# Client for AssemblyAI API
# Handles file uploads, transcription requests, and polling for results
class AssemblyAIClient
  API_BASE = 'https://api.assemblyai.com/v2'
  MAX_POLL_ATTEMPTS = 120 # 10 minutes with 5 second intervals
  POLL_INTERVAL = 5 # seconds

  class Error < StandardError; end
  class UploadError < Error; end
  class TranscriptionError < Error; end
  class PollError < Error; end

  def initialize(api_key)
    @api_key = api_key
    raise ArgumentError, 'API key is required' if @api_key.nil? || @api_key.empty?
  end

  # Upload a local file to AssemblyAI
  # @param file_path [String] Path to the local audio file
  # @return [String] Upload URL for the file
  # @raise [UploadError] if upload fails
  def upload_file(file_path)
    raise UploadError, "File not found: #{file_path}" unless File.exist?(file_path)

    uri = URI("#{API_BASE}/upload")
    
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 300 # 5 minutes for large files
    
    request = Net::HTTP::Post.new(uri.path)
    request['authorization'] = @api_key
    request['content-type'] = 'application/octet-stream'
    request.body = File.binread(file_path)
    
    response = http.request(request)
    
    if response.code.to_i == 200
      data = JSON.parse(response.body)
      data['upload_url']
    else
      raise UploadError, "Upload failed: #{response.code} - #{response.body}"
    end
  rescue JSON::ParserError => e
    raise UploadError, "Invalid JSON response: #{e.message}"
  rescue StandardError => e
    raise UploadError, "File upload error: #{e.message}"
  end

  # Create a transcription request
  # @param audio_url [String] URL to the audio file (uploaded or external)
  # @param options [Hash] Transcription options
  # @option options [String] :language_code Language code (e.g., 'en', 'es')
  # @option options [Boolean] :speaker_labels Enable speaker diarization
  # @option options [Boolean] :auto_highlights Extract key phrases
  # @option options [String] :speech_model Speech model to use ('universal-3-pro' or 'universal-2')
  # @return [String] Transcript ID
  # @raise [TranscriptionError] if request fails
  def create_transcript(audio_url, options = {})
    uri = URI("#{API_BASE}/transcript")
    
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    
    request = Net::HTTP::Post.new(uri.path)
    request['authorization'] = @api_key
    request['content-type'] = 'application/json'
    
    body = { audio_url: audio_url }
    # Default to universal-2 if no speech model specified
    body[:speech_models] = [options[:speech_model] || 'universal-2']
    body[:language_code] = options[:language_code] if options[:language_code]
    body[:speaker_labels] = options[:speaker_labels] if options[:speaker_labels]
    body[:auto_highlights] = options[:auto_highlights] if options[:auto_highlights]
    
    request.body = JSON.generate(body)
    
    response = http.request(request)
    
    if response.code.to_i == 200
      data = JSON.parse(response.body)
      data['id']
    else
      raise TranscriptionError, "Transcription request failed: #{response.code} - #{response.body}"
    end
  rescue JSON::ParserError => e
    raise TranscriptionError, "Invalid JSON response: #{e.message}"
  rescue StandardError => e
    raise TranscriptionError, "Transcription request error: #{e.message}"
  end

  # Poll for transcription completion
  # @param transcript_id [String] The transcript ID to poll
  # @return [Hash] Complete transcription result
  # @raise [PollError] if polling fails or times out
  def poll_transcript(transcript_id)
    uri = URI("#{API_BASE}/transcript/#{transcript_id}")
    
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    
    request = Net::HTTP::Get.new(uri.path)
    request['authorization'] = @api_key
    
    MAX_POLL_ATTEMPTS.times do |attempt|
      response = http.request(request)
      
      if response.code.to_i == 200
        data = JSON.parse(response.body)
        status = data['status']
        
        case status
        when 'completed'
          return data
        when 'error'
          raise PollError, "Transcription failed: #{data['error']}"
        when 'queued', 'processing'
          # Continue polling
          sleep POLL_INTERVAL unless attempt == MAX_POLL_ATTEMPTS - 1
        else
          raise PollError, "Unknown status: #{status}"
        end
      else
        raise PollError, "Polling failed: #{response.code} - #{response.body}"
      end
    end
    
    raise PollError, "Transcription timed out after #{MAX_POLL_ATTEMPTS * POLL_INTERVAL} seconds"
  rescue JSON::ParserError => e
    raise PollError, "Invalid JSON response: #{e.message}"
  end

  # Transcribe audio from URL or local file (convenience method)
  # @param audio_input [String] URL or local file path
  # @param options [Hash] Transcription options
  # @return [Hash] Complete transcription result
  def transcribe(audio_input, options = {})
    # If it's a local file, upload it first
    audio_url = if audio_input.start_with?('http://', 'https://')
      audio_input
    else
      upload_file(audio_input)
    end

    # Create transcription request
    transcript_id = create_transcript(audio_url, options)

    # Poll for completion
    poll_transcript(transcript_id)
  end
end
