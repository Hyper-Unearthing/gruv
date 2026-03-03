Dir[File.join(__dir__, 'lib', 'tools', '*.rb')].sort.each { |path| require path }
