# frozen_string_literal: true

module PlaneTools
  # Loads .env + the YAML project map.
  #
  # The YAML map is keyed by Plane project identifier (the short
  # prefix shown in work item IDs, e.g. "D4D" for "D4D-42"). Two
  # value shapes are supported, for backwards compatibility with
  # the original comments-only config:
  #
  #   D4D: forwarddemocracy/data4democracy        # legacy: just a repo
  #
  #   D4D:                                         # new: full config
  #     repo: forwarddemocracy/data4democracy
  #     priorities:
  #       "P0 - Urgent": urgent
  #       "P1 - high priority": high
  #       "P2 - medium priority": medium
  #       "P3 - low priority": low
  #
  # Bare-string entries get normalised to { repo: "..." } at load
  # time; consumers always see the hash shape.
  class Config
    # Order matters: earlier entries are MORE urgent. Used to pick a
    # winner when an issue has multiple priority labels.
    PRIORITY_RANK = %w[urgent high medium low none].freeze

    attr_reader :plane_token, :plane_slug, :plane_base,
                :github_token, :project_map, :root

    def self.load(root)
      new(root).tap(&:load!)
    end

    def initialize(root)
      @root = root
    end

    def load!
      load_env!
      load_project_map!
      self
    end

    def project(identifier)
      @project_map[identifier]
    end

    def each_project(&)
      @project_map.each(&)
    end

    # Returns true iff any project in the map has a non-empty
    # priorities: section. Used by the CLI to decide whether to run
    # the priority syncer at all.
    def priorities_configured?
      @project_map.any? { |_, entry| entry[:priorities] && !entry[:priorities].empty? }
    end

    private

    def load_env!
      env_path = File.expand_path(".env", @root)
      unless File.exist?(env_path)
        warn "error: #{env_path} not found"
        warn "       copy .env.example to .env and fill in your Plane + GitHub credentials."
        exit 1
      end
      Dotenv.load(env_path)

      @plane_token  = ENV.fetch("PLANE_API_TOKEN")
      @plane_slug   = ENV.fetch("PLANE_WORKSPACE_SLUG")
      @plane_base   = ENV.fetch("PLANE_BASE_URL", "https://api.plane.so")
      @github_token = ENV.fetch("GITHUB_TOKEN") { `gh auth token`.strip }
      raise "no GitHub token (set GITHUB_TOKEN or run gh auth login)" if @github_token.empty?
    end

    def load_project_map!
      map_path = File.expand_path("config/plane_github_map.yml", @root)
      unless File.exist?(map_path)
        warn "error: #{map_path} not found"
        warn "       copy config/plane_github_map.example.yml to config/plane_github_map.yml " \
             "and edit it for your projects."
        exit 1
      end
      raw = YAML.load_file(map_path)
      raise "config/plane_github_map.yml must be a Hash, got #{raw.class}" unless raw.is_a?(Hash)

      @project_map = raw.each_with_object({}) do |(ident, value), h|
        h[ident] = normalise_entry(ident, value)
      end
    end

    def normalise_entry(ident, value)
      case value
      when String
        { repo: value, priorities: nil }
      when Hash
        repo = value["repo"] || value[:repo]
        raise "project #{ident}: missing 'repo' key in #{value.inspect}" unless repo

        prios = value["priorities"] || value[:priorities]
        { repo: repo, priorities: validate_priorities(ident, prios) }
      else
        raise "project #{ident}: unsupported value type #{value.class} (#{value.inspect})"
      end
    end

    def validate_priorities(ident, prios)
      return nil if prios.nil?
      raise "project #{ident}: priorities: must be a Hash, got #{prios.class}" unless prios.is_a?(Hash)

      prios.each do |label, plane_prio|
        unless PRIORITY_RANK.include?(plane_prio.to_s)
          raise "project #{ident}: priority #{label.inspect} maps to invalid Plane priority " \
                "#{plane_prio.inspect} (allowed: #{PRIORITY_RANK.join(', ')})"
        end
      end
      prios.transform_values(&:to_s)
    end
  end
end
