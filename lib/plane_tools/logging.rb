# frozen_string_literal: true

module PlaneTools
  # Builds a Logger that tees to stdout + a file under tmp/.
  module Logging
    class TeeIO
      def initialize(*ios) = (@ios = ios)
      def write(*args) = @ios.each { |io| io.write(*args) }
      def close = @ios.each(&:close)
      def flush = @ios.each(&:flush)
      # Logger probes/sets `sync`; names match the IO contract.
      def sync = true # rubocop:disable Naming/PredicateMethod
      def sync=(_v); end # rubocop:disable Naming/MethodParameterName
    end

    def self.build(root:, name:)
      FileUtils.mkdir_p(File.join(root, "tmp"))
      log_path = File.join(root, "tmp", "#{name}.log")
      log_file = File.open(log_path, "a")
      log_file.sync = true

      log = Logger.new(TeeIO.new($stdout, log_file))
      log.formatter = ->(sev, time, _prog, msg) { "[#{time.strftime('%H:%M:%S')} #{sev}] #{msg}\n" }
      log
    end
  end
end
